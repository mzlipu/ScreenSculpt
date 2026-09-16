// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import ImageIO
import SSGeometry
import UniformTypeIdentifiers

/// Another image placed on the canvas — a logo, a cursor, a pasted crop.
///
/// The bytes live in the body rather than as a file reference. A document that
/// points at `~/Desktop/logo.png` is a document that breaks the moment the file
/// moves, and these are meant to be self-contained. The cost is document size,
/// so callers are expected to downscale before inserting; ``maximumBytes`` is
/// the ceiling past which insertion is refused rather than silently bloating.
public struct ImageOverlayBody: AnnotationBody {
    public static let kind = AnnotationKind.imageOverlay

    /// 8 MB. Large enough for any sensible overlay, small enough that a
    /// document stays openable.
    public static let maximumBytes = 8 * 1024 * 1024

    public var rect: ImageRect
    /// PNG bytes.
    public var data: Data
    /// Aspect ratio at insertion, so resizing can preserve it.
    public var naturalAspect: Double

    public init(rect: ImageRect, data: Data, naturalAspect: Double) {
        self.rect = rect
        self.data = data
        self.naturalAspect = naturalAspect > 0 ? naturalAspect : 1
    }

    public var bounds: ImageRect { rect }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect { rect.outsetBy(4) }

    public func handles(style: AnnotationStyle) -> [Handle] { Draw.corners(of: rect) }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self {
        guard case .corner(let corner) = edit.role else { return self }
        var copy = self
        var resized = Draw.resize(rect, corner: corner, to: edit.location, square: false)
        // Aspect is preserved unless Shift is held — the reverse of the shape
        // tools, because a stretched logo is almost never what was meant.
        if !edit.constrain {
            let height = resized.width.value / naturalAspect
            resized = ImageRect(
                origin: resized.origin,
                size: ImageSize(width: resized.width, height: ImagePx(height))
            )
        }
        copy.rect = resized
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

    /// Draws only the editing outline.
    ///
    /// The picture itself is drawn by the renderer, which owns the decode cache
    /// — decoding costs milliseconds and this runs on every redraw, so a body
    /// that decoded its own bytes would decode a PNG per frame while dragging.
    /// The same split as a blur, for the same reason.
    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        guard !render.isExport else { return }
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.stroke(rect.cgRect)
    }
}

/// Encoding overlays for storage.
enum ImageOverlayCodec {

    static func encode(_ image: CGImage, maximumDimension: Int = 2048) -> Data? {
        var source = image
        let longest = max(image.width, image.height)
        if longest > maximumDimension {
            let scale = Double(maximumDimension) / Double(longest)
            let width = Int(Double(image.width) * scale)
            let height = Int(Double(image.height) * scale)
            if let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let scaled = context.makeImage() { source = scaled }
            }
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, source, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension ImageOverlayBody {
    /// Build an overlay from an image, downscaling and encoding it.
    ///
    /// Returns nil past ``maximumBytes`` rather than accepting something that
    /// would make the document unwieldy.
    public static func make(from image: CGImage, at rect: ImageRect) -> ImageOverlayBody? {
        guard let data = ImageOverlayCodec.encode(image), data.count <= maximumBytes else {
            return nil
        }
        let aspect = image.height == 0 ? 1 : Double(image.width) / Double(image.height)
        return ImageOverlayBody(rect: rect, data: data, naturalAspect: aspect)
    }
}
