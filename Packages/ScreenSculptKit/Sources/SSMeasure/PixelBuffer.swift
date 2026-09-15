// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging

/// The image's pixels, decoded once into a flat RGBA buffer.
///
/// Every measurement operation walks raw bytes: colour picking, edge detection,
/// the ruler and auto-fit all need random access to thousands of pixels while
/// the cursor moves, and re-decoding a `CGImage` per query would make the
/// interaction laggy rather than instant.
///
/// Deliberately not Core Image: it works in a colour-managed float space, so
/// its numbers are not the numbers stored in the file — unacceptable for a tool
/// whose entire claim is reporting exact values.
public struct PixelBuffer: Sendable {

    public let width: Int
    public let height: Int
    private let bytes: [UInt8]

    /// Cached luminance plane, computed with the same coefficients the ruler
    /// and edge detector use.
    public let luminance: [Float]

    public init?(_ image: RasterImage) {
        let width = image.cgImage.width
        let height = image.cgImage.height
        guard width > 0, height > 0 else { return nil }

        var raw = [UInt8](repeating: 0, count: width * height * 4)
        let ok = raw.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        self.width = width
        self.height = height
        bytes = raw

        var plane = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let offset = index * 4
            // Rec. 709 weights, matching relativeLuminance, but on the
            // gamma-encoded values: edge detection wants perceived steps, and
            // linearising first over-weights highlights.
            plane[index] = 0.2126 * Float(raw[offset])
                + 0.7152 * Float(raw[offset + 1])
                + 0.0722 * Float(raw[offset + 2])
        }
        luminance = plane
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    public func color(x: Int, y: Int) -> RGBA8? {
        guard contains(x: x, y: y) else { return nil }
        let offset = (y * width + x) * 4
        return RGBA8(
            r: bytes[offset], g: bytes[offset + 1],
            b: bytes[offset + 2], a: bytes[offset + 3]
        )
    }

    public func color(at point: ImagePoint) -> RGBA8? {
        color(x: Int(point.x.value.rounded(.down)), y: Int(point.y.value.rounded(.down)))
    }

    public func luma(x: Int, y: Int) -> Float {
        guard contains(x: x, y: y) else { return 0 }
        return luminance[y * width + x]
    }
}

// MARK: - Sampling

public enum ColorSampler {

    /// Darkest pixel in a neighbourhood — the colour of text under the cursor.
    ///
    /// Uses a low percentile rather than the single darkest pixel: antialiasing
    /// puts a few near-black pixels at every glyph edge regardless of the text's
    /// actual colour, and the minimum would report those instead of the body of
    /// the stroke.
    public static func textColor(
        in buffer: PixelBuffer, around point: ImagePoint, radius: Int = 10
    ) -> RGBA8? {
        let centreX = Int(point.x.value), centreY = Int(point.y.value)
        var samples: [(luma: Float, color: RGBA8)] = []

        for y in (centreY - radius)...(centreY + radius) {
            for x in (centreX - radius)...(centreX + radius) {
                guard let color = buffer.color(x: x, y: y) else { continue }
                samples.append((buffer.luma(x: x, y: y), color))
            }
        }
        guard !samples.isEmpty else { return nil }

        samples.sort { $0.luma < $1.luma }
        let index = min(samples.count - 1, max(0, samples.count / 20))
        return samples[index].color
    }

    /// Mean colour of a region, averaged in **linear** space.
    ///
    /// Averaging gamma-encoded values is the classic error here and is visibly
    /// wrong on high-contrast selections: half black and half white averages to
    /// roughly 188, not the 128 people expect.
    public static func averageColor(in buffer: PixelBuffer, rect: ImageRect) -> RGBA8? {
        let minX = max(0, Int(rect.minX.value))
        let minY = max(0, Int(rect.minY.value))
        let maxX = min(buffer.width, Int(rect.maxX.value.rounded(.up)))
        let maxY = min(buffer.height, Int(rect.maxY.value.rounded(.up)))
        guard maxX > minX, maxY > minY else { return nil }

        var totals = (r: 0.0, g: 0.0, b: 0.0)
        var count = 0.0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = buffer.color(x: x, y: y) else { continue }
                totals.r += ColorSpaces.linearise(Double(color.r) / 255)
                totals.g += ColorSpaces.linearise(Double(color.g) / 255)
                totals.b += ColorSpaces.linearise(Double(color.b) / 255)
                count += 1
            }
        }
        guard count > 0 else { return nil }

        func encode(_ total: Double) -> UInt8 {
            let value = ColorSpaces.encode(total / count)
            return UInt8(max(0, min(255, (value * 255).rounded())))
        }
        return RGBA8(r: encode(totals.r), g: encode(totals.g), b: encode(totals.b))
    }
}
