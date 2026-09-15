// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSImaging

/// One captured frame reduced to 8-bit luminance.
///
/// Stitching never needs colour: alignment, sticky-band detection and overlap
/// verification all work on luminance, and carrying three channels through them
/// would triple the memory a long scroll holds for no gain in accuracy.
///
/// Stored as `UInt8` rather than `Float` deliberately. A 1200×2800 frame is
/// 3.4 MB here and 13 MB as floats, and a scroll session keeps several frames
/// alive at once; the correlator converts the few rows it actually compares.
public struct GrayFrame: Sendable {

    public let width: Int
    public let height: Int
    /// Row-major, one byte per pixel, `count == width * height`.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel count must match the dimensions")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Render a captured image down to luminance.
    ///
    /// Goes through a device-gray `CGContext` rather than averaging RGB by hand
    /// so the conversion matches what CoreGraphics does everywhere else in the
    /// app, including the colour-managed path for a wide-gamut display.
    public init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let base = raw.baseAddress,
                let context = CGContext(
                    data: base, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        self.init(width: width, height: height, pixels: buffer)
    }

    public init?(_ image: RasterImage) {
        self.init(image.cgImage)
    }

    /// Whether two frames show the same thing, sampled rather than compared in
    /// full — this runs between every poll of a settling page.
    ///
    /// The tolerance is not zero: a caret blinking or a shadow redrawing moves a
    /// row by a step or two, and treating that as movement would keep a settled
    /// page from ever being declared settled.
    public func matches(_ other: GrayFrame, tolerance: Double = 1.0) -> Bool {
        guard width == other.width, height == other.height else { return false }
        let step = max(1, height / 48)
        var total = 0.0
        var counted = 0
        var row = 0
        while row < height {
            total += rowDifference(row, against: other, row: row)
            counted += 1
            row += step
        }
        return counted > 0 && total / Double(counted) <= tolerance
    }

    /// Mean absolute difference between one row of this frame and one of another,
    /// in luminance steps (0…255).
    func rowDifference(_ row: Int, against other: GrayFrame, row otherRow: Int) -> Double {
        guard
            width == other.width,
            row >= 0, row < height,
            otherRow >= 0, otherRow < other.height
        else { return .infinity }

        var total = 0
        let lhs = row * width
        let rhs = otherRow * width
        pixels.withUnsafeBufferPointer { a in
            other.pixels.withUnsafeBufferPointer { b in
                for x in 0..<width {
                    total += abs(Int(a[lhs + x]) - Int(b[rhs + x]))
                }
            }
        }
        return Double(total) / Double(width)
    }
}
