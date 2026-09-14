// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import Testing

@testable import SSGeometry

// MARK: - Fixtures

/// A deliberately hostile three-display arrangement:
///
/// * the primary is **not** the topmost display, so the Cocoa→CG flip cannot be
///   done against the primary's height;
/// * scale factors are mixed (2× and 1×);
/// * one display is wider than the primary.
///
/// In Cocoa space (bottom-left origin, Y up):
/// ```
///   above : (0,    982, 2560, 1440)   1×    y 982…2422
///   main  : (0,      0, 1512,  982)   2×    y   0… 982   [primary]
///   right : (1512,   0, 3440, 1440)   1×    y   0…1440
/// ```
/// Union is (0, 0, 4952, 2422), so `globalCocoaBounds.maxY == 2422`.
///
/// Flipping to CG space (top-left origin, Y down) therefore puts the *primary*
/// display at y = 2422 − 982 = **1440**, not at zero. Code that assumes the
/// primary sits at the CG origin — or that flips against
/// `NSScreen.main!.frame.maxY` — is wrong here and correct on a single-display
/// development machine, which is exactly why this fixture exists.
enum Fixture {
    static let cocoaBounds = ScreenRect(x: 0, y: 0, width: 4952, height: 2422)

    static let above = DisplaySnapshot(
        displayID: 2, uuid: "UUID-ABOVE",
        frame: ScreenRect(x: 0, y: 0, width: 2560, height: 1440),
        scale: .x1, localizedName: "Above"
    )

    static let main = DisplaySnapshot(
        displayID: 1, uuid: "UUID-MAIN",
        frame: ScreenRect(x: 0, y: 1440, width: 1512, height: 982),
        scale: .x2, isPrimary: true, localizedName: "Built-in"
    )

    static let right = DisplaySnapshot(
        displayID: 3, uuid: "UUID-RIGHT",
        frame: ScreenRect(x: 1512, y: 982, width: 3440, height: 1440),
        scale: .x1, localizedName: "Ultrawide"
    )

    static let topology = DisplayTopology(
        displays: [above, main, right],
        globalCocoaBounds: cocoaBounds
    )
}

// MARK: - Unit tagging

@Suite("Unit tags")
struct UnitTests {

    @Test("Converting pixels to points and back is lossless")
    func pixelPointRoundTrip() {
        let scale = PixelScale.x2
        for raw in [0.0, 1, 7, 64, 1512, 3024.5] {
            let px = ImagePx(raw)
            #expect(px.inPoints(scale).inPixels(scale) == px)
        }
    }

    @Test("A 2x capture reports half as many logical points")
    func retinaConversion() {
        #expect(ImagePx(64).inPoints(.x2) == LogicalPt(32))
        #expect(LogicalPt(32).inPixels(.x2) == ImagePx(64))
        #expect(ImagePx(64).inPoints(.x1) == LogicalPt(64))
    }

    @Test("The logical/physical toggle never changes the stored value")
    func toggleIsDisplayOnly() {
        // The `P` shortcut must be a formatter change, never a recomputation.
        let measured = ImagePx(137)
        let shownAsPoints = measured.inPoints(.x2)
        #expect(measured == ImagePx(137))
        #expect(shownAsPoints == LogicalPt(68.5))
        #expect(shownAsPoints.inPixels(.x2) == measured)
    }

    @Test("Arithmetic stays inside one unit")
    func arithmetic() {
        #expect(ImagePx(10) + ImagePx(5) == ImagePx(15))
        #expect(ImagePx(10) * 2 == ImagePx(20))
        #expect(ImagePx(10) / ImagePx(4) == 2.5)  // ratio is dimensionless
        #expect((-ImagePx(3)).magnitude == ImagePx(3))
    }

    @Test("Scalars encode as bare numbers")
    func codableIsBare() throws {
        let data = try JSONEncoder().encode(ImagePx(12.5))
        #expect(String(bytes: data, encoding: .utf8) == "12.5")
        #expect(try JSONDecoder().decode(ImagePx.self, from: data) == ImagePx(12.5))
    }
}

// MARK: - Cocoa ↔ CoreGraphics

@Suite("Cocoa/CoreGraphics flip")
struct FlipTests {

    @Test("The primary display is not at the CG origin when another sits above it")
    func primaryIsNotAtOrigin() {
        // The regression this whole fixture exists to catch.
        #expect(Fixture.main.frame.minY == LogicalPt(1440))
        #expect(Fixture.above.frame.minY == LogicalPt(0))
    }

    @Test("Point flip round-trips")
    func pointRoundTrip() {
        let t = Fixture.topology
        for p in [
            ScreenPoint(x: 0, y: 0),
            ScreenPoint(x: 100, y: 100),
            ScreenPoint(x: 4952, y: 2422),
            ScreenPoint(x: 1512, y: 982),
        ] {
            #expect(t.cocoaPoint(fromCG: t.cgPoint(fromCocoa: p)) == p)
        }
    }

    @Test("Rect flip round-trips and preserves size")
    func rectRoundTrip() {
        let t = Fixture.topology
        let cocoa = ScreenRect(x: 120, y: 340, width: 500, height: 250)
        let cg = t.cgRect(fromCocoa: cocoa)
        #expect(cg.size == cocoa.size)
        #expect(t.cocoaRect(fromCG: cg) == cocoa)
    }

    @Test("The flip pivots on the union, not on the primary display")
    func flipUsesUnionHeight() {
        let t = Fixture.topology
        // A point at the Cocoa origin is the bottom-left of the whole
        // arrangement, so in CG space its Y is the union height.
        #expect(t.cgPoint(fromCocoa: ScreenPoint(x: 0, y: 0)).y == LogicalPt(2422))

        // Had the flip used the primary's height (982) this would be 982.
        #expect(t.cgPoint(fromCocoa: ScreenPoint(x: 0, y: 0)).y != LogicalPt(982))
    }
}

// MARK: - Topology queries

@Suite("Display topology")
struct TopologyTests {

    @Test("Points resolve to the display containing them")
    func hitTesting() {
        let t = Fixture.topology
        #expect(t.display(containing: ScreenPoint(x: 10, y: 10))?.displayID == 2)
        #expect(t.display(containing: ScreenPoint(x: 10, y: 1500))?.displayID == 1)
        #expect(t.display(containing: ScreenPoint(x: 3000, y: 1500))?.displayID == 3)
        #expect(t.display(containing: ScreenPoint(x: 9999, y: 9999)) == nil)
    }

    @Test("A rect straddling two displays resolves to the one it mostly covers")
    func dominantDisplay() {
        let t = Fixture.topology
        // Mostly on `main` (id 1), slightly overlapping `right` (id 3).
        let rect = ScreenRect(x: 1400, y: 1500, width: 200, height: 200)
        #expect(t.dominantDisplay(for: rect)?.displayID == 1)
    }

    @Test("Mixed-scale spans are detected so measurement can be disabled")
    func mixedScaleDetection() {
        let t = Fixture.topology
        // Wholly inside the 2x primary.
        #expect(!t.spansMixedScales(ScreenRect(x: 100, y: 1500, width: 200, height: 200)))
        // Straddles the 2x primary and the 1x ultrawide.
        #expect(t.spansMixedScales(ScreenRect(x: 1400, y: 1500, width: 400, height: 200)))
    }

    @Test("Displays are found by stable UUID, which survives a reconnect")
    func lookupByUUID() {
        // Display IDs are reassigned on undock/redock; pinned window positions
        // must key off the UUID or they land on the wrong monitor.
        #expect(Fixture.topology.display(uuid: "UUID-RIGHT")?.localizedName == "Ultrawide")
    }
}

// MARK: - CanvasTransform

@Suite("Canvas transform")
struct CanvasTransformTests {

    @Test("Image/canvas conversion round-trips at every zoom stop",
          arguments: CanvasTransform.zoomStops)
    func roundTripAtZoom(_ zoom: Double) {
        let t = CanvasTransform(
            zoom: zoom, imageOrigin: ImagePoint(x: 37, y: 91), backingScale: .x2
        )
        let p = ImagePoint(x: 512.25, y: 300.5)
        let back = t.toImage(t.toCanvas(p))
        #expect(abs(back.x.value - p.x.value) < 1e-9)
        #expect(abs(back.y.value - p.y.value) < 1e-9)
    }

    @Test("100% means one image pixel per device pixel")
    func hundredPercentIsPixelForPixel() {
        // On a 2x display, 1 image px at 100% occupies half a view point.
        let t = CanvasTransform(zoom: 1, imageOrigin: .zero, backingScale: .x2)
        #expect(t.toCanvas(ImagePx(2)) == ViewPt(1))

        // On a 1x display, 1 image px occupies a whole view point.
        let t1 = CanvasTransform(zoom: 1, imageOrigin: .zero, backingScale: .x1)
        #expect(t1.toCanvas(ImagePx(2)) == ViewPt(2))
    }

    @Test("A view-point tolerance converts to a zoom-dependent pixel tolerance")
    func toleranceScalesWithZoom() {
        // Hit slop must feel constant on screen, so in image space it shrinks
        // as you zoom in.
        let far = CanvasTransform(zoom: 0.25, imageOrigin: .zero, backingScale: .x2)
        let near = CanvasTransform(zoom: 16, imageOrigin: .zero, backingScale: .x2)
        #expect(far.toImage(ViewPt(9)) > near.toImage(ViewPt(9)))
    }

    @Test("Zooming about an anchor keeps that image pixel under the cursor")
    func zoomAnchoring() {
        let t = CanvasTransform(zoom: 1, imageOrigin: .zero, backingScale: .x2)
        let cursor = CanvasPoint(x: 400, y: 250)
        let before = t.toImage(cursor)
        let after = t.zoomed(to: 8, anchoredAt: cursor).toImage(cursor)
        #expect(abs(after.x.value - before.x.value) < 1e-9)
        #expect(abs(after.y.value - before.y.value) < 1e-9)
    }

    @Test("Pan offsets snap to whole device pixels")
    func devicePixelSnapping() {
        // Sub-pixel pan makes nearest-neighbour magnification shimmer.
        let t = CanvasTransform(
            zoom: 8, imageOrigin: ImagePoint(x: 10.031, y: 20.077), backingScale: .x2
        ).snappedToDevicePixels()
        #expect((t.imageOrigin.x.value * 8).rounded() == t.imageOrigin.x.value * 8)
        #expect((t.imageOrigin.y.value * 8).rounded() == t.imageOrigin.y.value * 8)
    }

    @Test("Zoom is clamped to the supported range")
    func zoomClamping() {
        #expect(CanvasTransform(zoom: 1000, imageOrigin: .zero, backingScale: .x2).zoom == 32)
        #expect(CanvasTransform(zoom: 0, imageOrigin: .zero, backingScale: .x2).zoom == 0.05)
    }

    @Test("Zoom stepping moves through the stops and stays in range")
    func zoomStepping() {
        let t = CanvasTransform(zoom: 1, imageOrigin: .zero, backingScale: .x2)
        #expect(t.nextZoomStop(increasing: true) == 2)
        #expect(t.nextZoomStop(increasing: false) == 2.0 / 3.0)
        #expect(t.with(zoom: 32).nextZoomStop(increasing: true) == 32)
        #expect(t.with(zoom: 0.05).nextZoomStop(increasing: false) == 0.05)
    }

    @Test("Rendering policy switches at 1:1 and ramps the grid in above 16x")
    func renderingPolicy() {
        let base = CanvasTransform.identity()
        #expect(!base.with(zoom: 0.5).usesNearestNeighbour)
        #expect(base.with(zoom: 1).usesNearestNeighbour)
        #expect(base.with(zoom: 8).pixelGridAlpha == 0)
        #expect(base.with(zoom: 24).pixelGridAlpha > 0)
        #expect(base.with(zoom: 32).pixelGridAlpha > base.with(zoom: 20).pixelGridAlpha)
    }

    @Test("Fit zoom never magnifies a small capture past 1:1")
    func fitZoomCap() {
        let zoom = CanvasTransform.fitZoom(
            image: ImageSize(width: 100, height: 100),
            viewport: CanvasSize(width: 2000, height: 2000),
            backingScale: .x2
        )
        #expect(zoom == 1.0)
    }
}

// MARK: - Rect algebra

@Suite("Image rect algebra")
struct ImageRectTests {

    @Test("A marquee dragged up-and-left still produces a positive rect")
    func normalisedFromCorners() {
        let r = ImageRect(
            corner: ImagePoint(x: 300, y: 200), opposite: ImagePoint(x: 100, y: 50)
        )
        #expect(r == ImageRect(x: 100, y: 50, width: 200, height: 150))
    }

    @Test("Intersection and union behave")
    func setOps() {
        let a = ImageRect(x: 0, y: 0, width: 100, height: 100)
        let b = ImageRect(x: 50, y: 50, width: 100, height: 100)
        #expect(a.intersection(b) == ImageRect(x: 50, y: 50, width: 50, height: 50))
        #expect(a.union(b) == ImageRect(x: 0, y: 0, width: 150, height: 150))
        #expect(a.intersection(ImageRect(x: 500, y: 500, width: 10, height: 10)).isEmpty)
        #expect(a.union(.zero) == a)
        #expect(ImageRect.zero.union(a) == a)
    }

    @Test("Invalidation rects grow outward to whole pixels")
    func integralOutward() {
        let r = ImageRect(x: 10.4, y: 20.6, width: 5.3, height: 5.1)
        let i = r.integralOutward()
        #expect(i.minX == ImagePx(10))
        #expect(i.minY == ImagePx(20))
        #expect(i.maxX >= r.maxX)
        #expect(i.maxY >= r.maxY)
    }

    @Test("Containment is half-open so adjacent rects do not both claim a pixel")
    func halfOpenContainment() {
        let r = ImageRect(x: 0, y: 0, width: 10, height: 10)
        #expect(r.contains(ImagePoint(x: 0, y: 0)))
        #expect(r.contains(ImagePoint(x: 9.99, y: 9.99)))
        #expect(!r.contains(ImagePoint(x: 10, y: 5)))
    }
}
