// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

/// An immutable captured image, together with the pixel scale it was captured
/// at.
///
/// This is the only `@unchecked Sendable` type in the codebase, and a SwiftLint
/// rule enforces that. The exemption is justified: `CGImage` is immutable once
/// created and CoreGraphics guarantees thread-safe reads, so passing one across
/// an isolation boundary is genuinely safe. Everywhere else, pass a
/// `RasterImage` rather than reaching for the attribute again.
public struct RasterImage: @unchecked Sendable {

    public let cgImage: CGImage

    /// Device pixels per logical point *for the capture*, frozen at capture
    /// time. Never re-derive this from the current screen: the user will drag
    /// the editor onto a 1× display and the image's scale does not change.
    public let pixelScale: PixelScale

    public init(cgImage: CGImage, pixelScale: PixelScale) {
        self.cgImage = cgImage
        self.pixelScale = pixelScale
    }

    public var size: ImageSize {
        ImageSize(pixelWidth: cgImage.width, pixelHeight: cgImage.height)
    }

    public var bounds: ImageRect { ImageRect(size: size) }

    /// Size in logical points — what the content measured on screen.
    public var logicalSize: (width: LogicalPt, height: LogicalPt) {
        (size.width.inPoints(pixelScale), size.height.inPoints(pixelScale))
    }

    public var colorSpace: CGColorSpace? { cgImage.colorSpace }

    // MARK: - Operations

    /// Crop to `rect`, expressed in image pixels.
    ///
    /// Returns nil if the intersection with the image bounds is empty, rather
    /// than trapping — a marquee can legitimately be dragged off the edge.
    public func cropped(to rect: ImageRect) -> RasterImage? {
        let clamped = rect.intersection(bounds).integralOutward().intersection(bounds)
        guard !clamped.isEmpty, let cropped = cgImage.cropping(to: clamped.cgRect) else {
            return nil
        }
        return RasterImage(cgImage: cropped, pixelScale: pixelScale)
    }

    /// Resample to an exact pixel size.
    ///
    /// `interpolation` should be `.none` when magnifying in the editor — a
    /// smoothed pixel is a lie about what was on screen — and `.high` when
    /// downscaling for export.
    public func resized(
        to newSize: ImageSize, interpolation: CGInterpolationQuality = .high
    ) -> RasterImage? {
        guard newSize.pixelWidth > 0, newSize.pixelHeight > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: newSize.pixelWidth,
            height: newSize.pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = interpolation
        context.draw(cgImage, in: CGRect(
            x: 0, y: 0, width: newSize.width.cgFloat, height: newSize.height.cgFloat
        ))
        guard let output = context.makeImage() else { return nil }
        return RasterImage(cgImage: output, pixelScale: pixelScale)
    }

    /// Downscale a Retina capture to 1×, for people who want the file to match
    /// the logical size they measured.
    public func downscaledTo1x() -> RasterImage? {
        guard pixelScale.isRetina else { return self }
        let target = ImageSize(
            width: ImagePx(size.width.value / pixelScale.value),
            height: ImagePx(size.height.value / pixelScale.value)
        )
        guard let scaled = resized(to: target) else { return nil }
        return RasterImage(cgImage: scaled.cgImage, pixelScale: .x1)
    }

    /// Colour of a single pixel, read from the raw bytes in the image's own
    /// colour space.
    ///
    /// Deliberately not routed through Core Image, which works in a
    /// colour-managed float space and would return numbers that are not the
    /// numbers in the file.
    public func pixelColor(at point: ImagePoint) -> RGBA8? {
        let x = Int(point.x.value), y = Int(point.y.value)
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else { return nil }

        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(
            x: -x, y: -(cgImage.height - 1 - y),
            width: cgImage.width, height: cgImage.height
        ))
        return RGBA8(r: pixel[0], g: pixel[1], b: pixel[2], a: pixel[3])
    }
}

/// An 8-bit-per-channel colour read straight from an image's stored bytes.
///
/// A named type rather than a tuple because the colour tooling — hex, OKLCh,
/// WCAG and APCA contrast — all needs somewhere to hang, and positional tuple
/// members invite channel-order mistakes.
public struct RGBA8: Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public var hexString: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Relative luminance per WCAG 2.x, computed in linear space.
    ///
    /// Averaging or comparing gamma-encoded values is the classic bug here and
    /// is visibly wrong on high-contrast pairs.
    public var relativeLuminance: Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255.0
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
}
