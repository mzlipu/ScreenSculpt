// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import CoreImage
import Foundation
import SSGeometry

public enum ConcealMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case pixelate
    case blur
    case solid

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .solid: "Solid block"
        }
    }

    /// Whether the original pixels can in principle be recovered from the
    /// result. Surfaced in the UI, because "I blurred it" is a claim people
    /// make about screenshots they then publish.
    public var isIrreversible: Bool {
        switch self {
        case .pixelate: true      // averaged over a block; information is gone
        case .blur: false         // small-radius Gaussian is partially invertible
        case .solid: true
        }
    }
}

/// Hides a region of the underlying image.
///
/// Note this is an *annotation*, not a raster operation: the pixels beneath
/// survive until the document is flattened. That makes the region repositionable,
/// but it also means an unflattened document still contains what was hidden —
/// which is why export always flattens, and why the UI warns before sharing.
public struct ConcealBody: AnnotationBody {
    public static let kind = AnnotationKind.conceal

    public var rect: ImageRect
    public var mode: ConcealMode
    /// Pixel block size, or Gaussian radius, in image pixels.
    public var intensity: Double

    public init(rect: ImageRect, mode: ConcealMode = .pixelate, intensity: Double = 12) {
        self.rect = rect
        self.mode = mode
        self.intensity = intensity
    }

    public var bounds: ImageRect { rect }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect { rect.outsetBy(4) }

    public func handles(style: AnnotationStyle) -> [Handle] { Draw.corners(of: rect) }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self {
        guard case .corner(let corner) = edit.role else { return self }
        var copy = self
        copy.rect = Draw.resize(rect, corner: corner, to: edit.location, square: edit.constrain)
        return copy
    }

    public func translated(by delta: ImageVector) -> Self {
        var copy = self
        copy.rect = rect.offsetBy(delta)
        return copy
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        if let role = hitHandle(point, tolerance: tolerance, style: style) { return .handle(role) }
        return rect.outsetBy(tolerance).contains(point) ? .body : nil
    }

    /// Draws only the placeholder.
    ///
    /// The real effect needs the pixels underneath, which a body never sees —
    /// `ConcealRenderer` handles it in the render pass, where the base image is
    /// available. Keeping it that way is what stops every body needing a
    /// reference to the document.
    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        guard !render.isExport else { return }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(rect.cgRect)
    }
}

/// Applies conceal effects against the real pixels.
///
/// Lives outside the body because it needs the base image. Called once per
/// render pass with the already-composited raster.
public enum ConcealRenderer {

    /// One process-wide context. Constructing a `CIContext` is expensive enough
    /// that doing it per effect dominates the cost of the effect itself.
    private static let shared: CIContext = {
        CIContext(options: [.cacheIntermediates: false])
    }()

    /// Render `body` over `image`, returning just the concealed patch and where
    /// it belongs.
    public static func patch(
        for body: ConcealBody, in image: CGImage
    ) -> (image: CGImage, rect: CGRect)? {
        let imageBounds = ImageRect(pixelWidth: image.width, pixelHeight: image.height)
        let clamped = body.rect.intersection(imageBounds).integralOutward()
            .intersection(imageBounds)
        guard !clamped.isEmpty, let cropped = image.cropping(to: clamped.cgRect) else {
            return nil
        }

        switch body.mode {
        case .solid:
            return (solidPatch(size: clamped, from: cropped) ?? cropped, clamped.cgRect)
        case .pixelate:
            return (filtered(cropped, filter: pixelateFilter(body.intensity)) ?? cropped,
                    clamped.cgRect)
        case .blur:
            return (filtered(cropped, filter: blurFilter(body.intensity)) ?? cropped,
                    clamped.cgRect)
        }
    }

    private static func pixelateFilter(_ intensity: Double) -> (CIImage) -> CIImage? {
        { input in
            guard let filter = CIFilter(name: "CIPixellate") else { return nil }
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(max(intensity, 2), forKey: kCIInputScaleKey)
            // Anchor to the patch origin so blocks align to the region rather
            // than to the full image, which would shift them as it is dragged.
            filter.setValue(
                CIVector(x: input.extent.minX, y: input.extent.minY), forKey: kCIInputCenterKey
            )
            return filter.outputImage
        }
    }

    private static func blurFilter(_ intensity: Double) -> (CIImage) -> CIImage? {
        { input in
            // Clamp first, or the blur samples transparent black outside the
            // patch and the edges wash out.
            let clamped = input.clampedToExtent()
            guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
            filter.setValue(clamped, forKey: kCIInputImageKey)
            filter.setValue(max(intensity, 1), forKey: kCIInputRadiusKey)
            return filter.outputImage?.cropped(to: input.extent)
        }
    }

    private static func filtered(
        _ image: CGImage, filter: (CIImage) -> CIImage?
    ) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let output = filter(input) else { return nil }
        return shared.createCGImage(output, from: input.extent)
    }

    /// Fills with the modal colour of a ring just outside the region, so an
    /// erase blends into dark mode instead of stamping a white slab on it.
    private static func solidPatch(size: ImageRect, from patch: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: patch.width, height: patch.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let average = averageColor(of: patch) ?? CGColor(gray: 0.5, alpha: 1)
        context.setFillColor(average)
        context.fill(CGRect(x: 0, y: 0, width: patch.width, height: patch.height))
        return context.makeImage()
    }

    private static func averageColor(of image: CGImage) -> CGColor? {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGColor(
            red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255,
            blue: Double(pixel[2]) / 255, alpha: 1
        )
    }
}

extension ImageRect {
    init(pixelWidth: Int, pixelHeight: Int) {
        self.init(size: ImageSize(pixelWidth: pixelWidth, pixelHeight: pixelHeight))
    }
}
