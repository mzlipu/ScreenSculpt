// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import ImageIO
import Foundation
import SSGeometry
import Testing

@testable import SSAnnotations

private func point(_ x: Double, _ y: Double) -> ImagePoint {
    ImagePoint(x: ImagePx(x), y: ImagePx(y))
}

private let style = AnnotationStyle()

// MARK: - Spotlight

@Suite("Spotlight")
struct SpotlightTests {

    /// The lit region is the handle. Clicking the dimmed part has to fall
    /// through to whatever is underneath, or a spotlight covering the canvas
    /// would make everything else unselectable.
    @Test("Only the lit region is grabbable")
    func hitTestIsInsideOnly() {
        let body = SpotlightBody(rect: ImageRect(x: 50, y: 50, width: 100, height: 100))
        #expect(body.hitTest(point(100, 100), tolerance: ImagePx(3), style: style) == .body)
        #expect(body.hitTest(point(10, 10), tolerance: ImagePx(3), style: style) == nil)
    }

    @Test("Dragging a corner resizes the lit region")
    func resizes() {
        let body = SpotlightBody(rect: ImageRect(x: 50, y: 50, width: 100, height: 100))
        let edited = body.applying(
            HandleEdit(role: .corner(.bottomRight), location: point(200, 180), constrain: false),
            style: style
        )
        #expect(edited.rect.maxX == ImagePx(200))
        #expect(edited.rect.maxY == ImagePx(180))
    }

    @Test("Dimming is clamped to a usable range")
    func dimmingClamped() {
        // Values outside 0…1 come from serialised documents and from sliders
        // that have been dragged past their ends.
        let body = SpotlightBody(
            rect: ImageRect(x: 0, y: 0, width: 10, height: 10), dimming: 4
        )
        let context = CGContext(
            data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Would trap on an out-of-range alpha if it were not clamped.
        body.draw(in: context, style: style, render: RenderContext(
            pixelScale: .x1, isExport: true,
            imageBounds: ImageRect(x: 0, y: 0, width: 20, height: 20)
        ))
    }
}

// MARK: - Magnifier

@Suite("Magnifier")
struct MagnifierTests {

    /// The source is derived, not stored — so it cannot drift away from the
    /// lens as the lens is moved.
    @Test("The magnified region is centred on the lens and smaller by the zoom")
    func sourceFollowsLens() {
        let body = MagnifierBody(
            rect: ImageRect(x: 100, y: 100, width: 80, height: 80), zoom: 4
        )
        #expect(body.sourceRect.width == ImagePx(20))
        #expect(body.sourceRect.midX == body.rect.midX)
        #expect(body.sourceRect.midY == body.rect.midY)
    }

    @Test("Moving the lens moves what it shows")
    func sourceTranslates() {
        let body = MagnifierBody(rect: ImageRect(x: 10, y: 10, width: 40, height: 40))
        let moved = body.translated(by: ImageVector(dx: ImagePx(25), dy: ImagePx(-5)))
        #expect(moved.sourceRect.midX == body.sourceRect.midX + ImagePx(25))
        #expect(moved.sourceRect.midY == body.sourceRect.midY - ImagePx(5))
    }

    /// A zoom at or below 1 is a reduction, which is not what a loupe is for,
    /// and at exactly 1 the source equals the lens and nothing appears to
    /// happen at all.
    @Test("Zoom cannot be set below a magnification")
    func zoomFloor() {
        #expect(MagnifierBody(rect: .zero, zoom: 0.2).zoom > 1)
        #expect(MagnifierBody(rect: .zero, zoom: -3).zoom > 1)
    }

    @Test("A circular lens stays square while resizing")
    func circularStaysSquare() {
        let body = MagnifierBody(
            rect: ImageRect(x: 0, y: 0, width: 50, height: 50), isCircular: true
        )
        let edited = body.applying(
            HandleEdit(role: .corner(.bottomRight), location: point(140, 80), constrain: false),
            style: style
        )
        #expect(edited.rect.width == edited.rect.height, "got \(edited.rect)")
    }

    @Test("A source outside the image yields no patch rather than a crash")
    func refusesOffImageSource() {
        let image = CGContext(
            data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!.makeImage()!
        let body = MagnifierBody(rect: ImageRect(x: 500, y: 500, width: 50, height: 50))
        #expect(MagnifierRenderer.patch(for: body, in: image) == nil)
    }
}

// MARK: - Ruler

@Suite("Ruler")
struct RulerTests {

    @Test("Length is reported in whole pixels")
    func measuresPixels() {
        let body = RulerBody(start: point(10, 10), end: point(110, 10))
        #expect(body.measurement(scale: .x1) == "100 px")
    }

    /// Points come from the capture's own scale. A ruler that read the current
    /// display would change its answer when the window moved to another one.
    @Test("Points are derived from the capture scale, not the display")
    func measuresPoints() {
        let body = RulerBody(start: point(0, 0), end: point(200, 0), unit: .points)
        #expect(body.measurement(scale: .x2) == "100 pt")
        #expect(body.measurement(scale: .x1) == "200 pt")
    }

    @Test("Endpoints are dragged independently")
    func endpointsMove() {
        let body = RulerBody(start: point(0, 0), end: point(100, 0))
        let edited = body.applying(
            HandleEdit(role: .endpoint(true), location: point(20, 40), constrain: false),
            style: style
        )
        #expect(edited.start == point(20, 40))
        #expect(edited.end == body.end)
    }

    @Test("The line is grabbable along its length, not only at its ends")
    func hitTestAlongLine() {
        let body = RulerBody(start: point(0, 50), end: point(200, 50))
        #expect(body.hitTest(point(100, 51), tolerance: ImagePx(3), style: style) == .body)
        #expect(body.hitTest(point(100, 140), tolerance: ImagePx(3), style: style) == nil)
    }
}

// MARK: - Image overlay

@Suite("Image overlay")
struct ImageOverlayTests {

    private func swatch(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test("An overlay carries its own bytes")
    func embedsData() throws {
        let body = try #require(
            ImageOverlayBody.make(from: swatch(width: 40, height: 20), at: .zero)
        )
        #expect(!body.data.isEmpty)
        #expect(abs(body.naturalAspect - 2) < 0.01)
    }

    /// A stretched logo is almost never intended, so aspect holds by default
    /// and Shift is what releases it — the opposite of the shape tools.
    @Test("Resizing preserves the aspect ratio unless overridden")
    func preservesAspect() throws {
        let body = try #require(
            ImageOverlayBody.make(
                from: swatch(width: 40, height: 20),
                at: ImageRect(x: 0, y: 0, width: 40, height: 20)
            )
        )
        let kept = body.applying(
            HandleEdit(role: .corner(.bottomRight), location: point(120, 200), constrain: false),
            style: style
        )
        #expect(abs(kept.rect.width.value / kept.rect.height.value - 2) < 0.01)

        let free = body.applying(
            HandleEdit(role: .corner(.bottomRight), location: point(120, 200), constrain: true),
            style: style
        )
        #expect(free.rect.height == ImagePx(200))
    }

    /// Oversized images are downscaled on insert rather than embedded whole,
    /// or a document would grow past the point of being openable.
    @Test("A large image is reduced before it is stored")
    func downscalesLargeImages() throws {
        let body = try #require(
            ImageOverlayBody.make(from: swatch(width: 5000, height: 2500), at: .zero)
        )
        #expect(body.data.count <= ImageOverlayBody.maximumBytes)
        let decoded = try #require(
            CGImageSourceCreateWithData(body.data as CFData, nil)
                .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        )
        #expect(max(decoded.width, decoded.height) <= 2048)
        #expect(abs(body.naturalAspect - 2) < 0.01)
    }

    @Test("Overlays survive a serialisation round trip")
    func codableRoundTrip() throws {
        let body = try #require(
            ImageOverlayBody.make(
                from: swatch(width: 30, height: 30),
                at: ImageRect(x: 5, y: 6, width: 30, height: 30)
            )
        )
        let data = try JSONEncoder().encode(AnyAnnotationBody.imageOverlay(body))
        let decoded = try JSONDecoder().decode(AnyAnnotationBody.self, from: data)
        #expect(decoded == .imageOverlay(body))
    }
}
