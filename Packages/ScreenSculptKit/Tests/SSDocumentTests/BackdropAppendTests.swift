// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSAnnotations
import SSImaging
import Testing

@testable import SSDocument

private func swatch(_ width: Int, _ height: Int, gray: Double) -> RasterImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)
}

@Suite("Backdrop")
struct BackdropTests {

    @Test("Padding grows the canvas on both sides")
    func padsSymmetrically() {
        let image = swatch(200, 100, gray: 0.5)
        let wrapped = Backdrop(paddingFraction: 0.1).apply(to: image)
        // Padding is a fraction of the shorter side: 10% of 100 is 10 each way.
        #expect(wrapped.size.pixelWidth == 220)
        #expect(wrapped.size.pixelHeight == 120)
    }

    @Test("The background is painted around the screenshot")
    func paintsBackground() {
        let image = swatch(80, 80, gray: 1)
        let wrapped = Backdrop(
            paddingFraction: 0.25, cornerRadius: 0, shadowRadius: 0, shadowOpacity: 0,
            background: .solid(Backdrop.RGBA(r: 1, g: 0, b: 0))
        ).apply(to: image)

        let corner = wrapped.pixelColor(at: ImagePoint(x: ImagePx(2), y: ImagePx(2)))
        #expect(corner?.r ?? 0 > 200, "the corner should be background, got \(corner as Any)")
        #expect(corner?.g ?? 255 < 60)
    }

    /// Zero padding is a legitimate setting — someone may want only rounded
    /// corners — and must not produce a zero-sized canvas.
    @Test("Zero padding still produces the image")
    func zeroPadding() {
        let wrapped = Backdrop(paddingFraction: 0).apply(to: swatch(40, 40, gray: 0.5))
        #expect(wrapped.size.pixelWidth == 40)
        #expect(wrapped.size.pixelHeight == 40)
    }

    @Test("A backdrop survives a round trip through Codable")
    func codable() throws {
        let backdrop = Backdrop.dark
        let data = try JSONEncoder().encode(backdrop)
        #expect(try JSONDecoder().decode(Backdrop.self, from: data) == backdrop)
    }
}

@Suite("Backdrop on a document")
@MainActor
struct BackdropDocumentTests {

    /// The editor draws `render()`, so a backdrop has to be in it — otherwise
    /// the feature is invisible until the file is saved.
    /// Reads the raster first, the way the editor does when it opens. Setting
    /// the backdrop on a store that had never rendered would pass whatever the
    /// cache key was, and miss the one case that matters.
    @Test("The canvas grows as soon as a backdrop is set")
    func visibleInTheEditor() {
        let store = DocumentStore(image: swatch(200, 100, gray: 0.8))
        #expect(store.raster.size.pixelWidth == 200, "precondition")

        store.setBackdrop(Backdrop(paddingFraction: 0.1))
        #expect(store.raster.size.pixelWidth == 220)
        #expect(store.raster.size.pixelHeight == 120)

        store.setBackdrop(nil)
        #expect(store.raster.size.pixelWidth == 200, "the cache held a padded raster")
    }

    /// The reason this is not a plain property assignment. Padding moves the
    /// picture inside the canvas; markup left behind would point at the wrong
    /// thing.
    @Test("Annotations move with the padding")
    func annotationsFollow() throws {
        let store = DocumentStore(image: swatch(200, 100, gray: 0.8))
        store.add(
            .rectangle(RectangleBody(rect: ImageRect(x: 20, y: 20, width: 40, height: 30))),
            style: AnnotationStyle()
        )
        store.setBackdrop(Backdrop(paddingFraction: 0.1))   // 10px each side

        let moved = try #require(store.annotations.all.first)
        #expect(moved.bounds.minX == ImagePx(30))
        #expect(moved.bounds.minY == ImagePx(30))
    }

    @Test("Removing a backdrop puts them back")
    func annotationsReturn() throws {
        let store = DocumentStore(image: swatch(200, 100, gray: 0.8))
        store.add(
            .rectangle(RectangleBody(rect: ImageRect(x: 20, y: 20, width: 40, height: 30))),
            style: AnnotationStyle()
        )
        store.setBackdrop(Backdrop(paddingFraction: 0.1))
        store.setBackdrop(nil)

        let restored = try #require(store.annotations.all.first)
        #expect(restored.bounds.minX == ImagePx(20))
        #expect(restored.bounds.minY == ImagePx(20))
        #expect(store.raster.size.pixelWidth == 200)
    }

    /// Flatten must not frame the frame: `render()` already applied it.
    @Test("Flatten does not apply the backdrop twice")
    func flattenedOnce() {
        let store = DocumentStore(image: swatch(200, 100, gray: 0.8))
        store.setBackdrop(Backdrop(paddingFraction: 0.1))
        store.add(
            .rectangle(RectangleBody(rect: ImageRect(x: 30, y: 30, width: 40, height: 30))),
            style: AnnotationStyle()
        )
        #expect(store.raster.size.pixelWidth == 220)
    }
}

@Suite("Append capture")
@MainActor
struct AppendTests {

    @Test("Appending below stacks the heights")
    func appendsBelow() {
        let store = DocumentStore(image: swatch(120, 80, gray: 0.9))
        store.append(swatch(120, 60, gray: 0.2), at: .bottom)
        #expect(store.raster.size.pixelWidth == 120)
        #expect(store.raster.size.pixelHeight == 140)
    }

    @Test("Appending beside adds the widths")
    func appendsRight() {
        let store = DocumentStore(image: swatch(120, 80, gray: 0.9))
        store.append(swatch(50, 80, gray: 0.2), at: .right)
        #expect(store.raster.size.pixelWidth == 170)
        #expect(store.raster.size.pixelHeight == 80)
    }

    /// The reason appending is restricted to the bottom and the right: those
    /// are the two edges that leave the origin where it was, so annotations
    /// already placed stay over what they were pointing at.
    @Test("Existing annotations keep their position")
    func annotationsUnmoved() {
        let store = DocumentStore(image: swatch(120, 80, gray: 0.9))
        store.add(
            .rectangle(RectangleBody(rect: ImageRect(x: 10, y: 10, width: 30, height: 20))),
            style: AnnotationStyle()
        )
        let before = store.annotations.all.first?.bounds
        store.append(swatch(120, 60, gray: 0.2), at: .bottom)
        #expect(store.annotations.all.first?.bounds == before)
    }

    @Test("A mismatched width is centred rather than stretched")
    func centresNarrowerAddition() {
        let store = DocumentStore(image: swatch(200, 40, gray: 0.9))
        store.append(swatch(80, 40, gray: 0.1), at: .bottom)
        #expect(store.raster.size.pixelWidth == 200, "the canvas should follow the wider image")

        // The narrower addition sits centred, so its own edges are background.
        let left = store.raster.pixelColor(at: ImagePoint(x: ImagePx(5), y: ImagePx(60)))
        let middle = store.raster.pixelColor(at: ImagePoint(x: ImagePx(100), y: ImagePx(60)))
        #expect((left?.r ?? 0) > 200, "expected background at the edge")
        #expect((middle?.r ?? 255) < 80, "expected the appended image in the middle")
    }

    @Test("Appending is undoable")
    func undoable() {
        let store = DocumentStore(image: swatch(120, 80, gray: 0.9))
        store.append(swatch(120, 60, gray: 0.2), at: .bottom)
        store.undo()
        #expect(store.raster.size.pixelHeight == 80)
    }
}
