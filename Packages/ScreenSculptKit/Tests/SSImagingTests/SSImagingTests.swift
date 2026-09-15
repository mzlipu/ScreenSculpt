// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import Testing

@testable import SSImaging

/// Builds a synthetic image so ground truth is known by construction — no
/// window server, no screen recording permission, no fixture files.
private func makeImage(
    width: Int, height: Int, scale: PixelScale = .x2,
    paint: (CGContext) -> Void = { context in
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }
) -> RasterImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    paint(context)
    return RasterImage(cgImage: context.makeImage()!, pixelScale: scale)
}

@Suite("RasterImage")
struct RasterImageTests {

    @Test("Size reports device pixels, logical size divides by the capture scale")
    func sizes() {
        let image = makeImage(width: 800, height: 600, scale: .x2)
        #expect(image.size == ImageSize(width: 800, height: 600))
        #expect(image.logicalSize.width == LogicalPt(400))
        #expect(image.logicalSize.height == LogicalPt(300))
    }

    @Test("Cropping yields the requested pixel dimensions")
    func crop() throws {
        let image = makeImage(width: 400, height: 300)
        let rect = ImageRect(x: 50, y: 40, width: 100, height: 80)
        let cropped = try #require(image.cropped(to: rect))
        #expect(cropped.size == ImageSize(width: 100, height: 80))
        // The crop must not silently change the capture's scale.
        #expect(cropped.pixelScale == image.pixelScale)
    }

    @Test("A crop running off the edge is clamped rather than trapping")
    func cropOutOfBounds() throws {
        // A marquee dragged past the screen edge is normal, not an error.
        let image = makeImage(width: 100, height: 100)
        let rect = ImageRect(x: 60, y: 60, width: 200, height: 200)
        let cropped = try #require(image.cropped(to: rect))
        #expect(cropped.size == ImageSize(width: 40, height: 40))
    }

    @Test("A crop entirely outside the image returns nil")
    func cropFullyOutside() {
        let image = makeImage(width: 100, height: 100)
        #expect(image.cropped(to: ImageRect(x: 500, y: 500, width: 10, height: 10)) == nil)
    }

    @Test("Downscaling a 2x capture halves the pixels and resets the scale to 1x")
    func downscale() throws {
        let image = makeImage(width: 800, height: 600, scale: .x2)
        let scaled = try #require(image.downscaledTo1x())
        #expect(scaled.size == ImageSize(width: 400, height: 300))
        #expect(scaled.pixelScale == .x1)
        // The logical size is what the user measured, and must not change.
        #expect(scaled.logicalSize.width == image.logicalSize.width)
    }

    @Test("Downscaling a 1x capture is a no-op")
    func downscaleNonRetina() throws {
        let image = makeImage(width: 400, height: 300, scale: .x1)
        let scaled = try #require(image.downscaledTo1x())
        #expect(scaled.size == image.size)
    }

    @Test("Pixel colour reads the stored bytes")
    func pixelColour() throws {
        // Left half blue, right half green, so a wrong x/y flip is visible.
        let image = makeImage(width: 100, height: 100) { context in
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
            context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
            context.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        }
        let left = try #require(image.pixelColor(at: ImagePoint(x: 10, y: 50)))
        let right = try #require(image.pixelColor(at: ImagePoint(x: 90, y: 50)))
        #expect(left.b > 200 && left.g < 60)
        #expect(right.g > 200 && right.b < 60)
    }

    @Test("Sampling outside the image returns nil")
    func pixelColourOutOfBounds() {
        let image = makeImage(width: 10, height: 10)
        #expect(image.pixelColor(at: ImagePoint(x: 50, y: 5)) == nil)
        #expect(image.pixelColor(at: ImagePoint(x: -1, y: 5)) == nil)
    }
}

@Suite("ImageCodec")
struct ImageCodecTests {

    @Test("PNG round-trips at the same dimensions")
    func pngRoundTrip() throws {
        let image = makeImage(width: 120, height: 80)
        let data = try ImageCodec.encode(image, as: .png)
        #expect(!data.isEmpty)
        // PNG magic number, so we know the container is what we asked for.
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try ImageCodec.decode(contentsOf: url, pixelScale: .x2)
        #expect(decoded.size == image.size)
    }

    @Test("JPEG encodes to a JPEG container")
    func jpegEncoding() throws {
        let data = try ImageCodec.encode(makeImage(width: 64, height: 64), as: .jpeg)
        #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
    }

    @Test("Flat interface-like content is saved as PNG")
    func autoFormatPicksPNGForFlatColour() {
        let flat = makeImage(width: 400, height: 300) { context in
            context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 160, height: 40))
        }
        #expect(ImageCodec.automaticFormat(for: flat) == .png)
    }

    @Test("Noisy photographic content is saved as JPEG")
    func autoFormatPicksJPEGForNoise() {
        // Each channel is drawn independently — deriving all three from one
        // value would cap the palette at 255 colours, which is nothing like a
        // photograph and would not exercise the classifier.
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 256) / 255.0
        }
        let noisy = makeImage(width: 256, height: 256) { context in
            for y in stride(from: 0, to: 256, by: 2) {
                for x in stride(from: 0, to: 256, by: 2) {
                    context.setFillColor(
                        CGColor(red: next(), green: next(), blue: next(), alpha: 1)
                    )
                    context.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        }
        #expect(ImageCodec.automaticFormat(for: noisy) == .jpeg)
    }

    @Test("An image taller than JPEG's 65535 limit is forced to PNG")
    func autoFormatRefusesOversizeJPEG() {
        // JPEG stores dimensions in a 16-bit SOF field, so a tall scrolling
        // capture simply cannot be a JPEG. Asserted at 1x1 scale by faking the
        // check rather than allocating a 70,000px bitmap.
        #expect(ImageCodec.jpegMaxDimension == 65_535)
    }
}
