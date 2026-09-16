// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

/// A loupe: enlarges whatever sits beneath it, in place.
///
/// Only one rectangle is stored. The region it magnifies is that rectangle
/// shrunk about its own centre by the zoom factor, which means dragging the
/// lens moves the subject with it and there is no second thing to keep aligned.
/// A separate source rectangle would be more general and much easier to leave
/// pointing at the wrong place.
///
/// Like a blur, the pixels come from the base image, which a body never sees —
/// ``MagnifierRenderer`` does the enlarging in the render pass.
public struct MagnifierBody: AnnotationBody {
    public static let kind = AnnotationKind.magnifier

    public var rect: ImageRect
    /// How much bigger. Below 1 this would be a reducer, which nobody wants.
    public var zoom: Double
    public var isCircular: Bool

    public init(rect: ImageRect, zoom: Double = 2.5, isCircular: Bool = true) {
        self.rect = rect
        self.zoom = max(1.1, zoom)
        self.isCircular = isCircular
    }

    public var bounds: ImageRect { rect }

    /// The region being enlarged.
    public var sourceRect: ImageRect {
        let width = rect.width.value / zoom
        let height = rect.height.value / zoom
        return ImageRect(
            x: ImagePx(rect.midX.value - width / 2),
            y: ImagePx(rect.midY.value - height / 2),
            width: ImagePx(width), height: ImagePx(height)
        )
    }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        rect.outsetBy(ImagePx(style.strokeWidth * 2 + 6))
    }

    public func handles(style: AnnotationStyle) -> [Handle] { Draw.corners(of: rect) }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self {
        guard case .corner(let corner) = edit.role else { return self }
        var copy = self
        // Circular lenses resize square whether or not Shift is held: an
        // ellipse would magnify the two axes differently and distort what it
        // is meant to be showing accurately.
        copy.rect = Draw.resize(
            rect, corner: corner, to: edit.location, square: edit.constrain || isCircular
        )
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

    /// Draws the rim only. The enlargement needs the pixels underneath, which
    /// the renderer supplies.
    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        let path = isCircular
            ? CGPath(ellipseIn: rect.cgRect, transform: nil)
            : CGPath(
                roundedRect: rect.cgRect, cornerWidth: 6, cornerHeight: 6, transform: nil
            )
        Draw.applyStroke(style, to: context)
        context.setLineDash(phase: 0, lengths: [])
        context.addPath(path)
        context.strokePath()
    }
}

/// Produces the enlarged patch.
///
/// Outside the body because it needs the base image, and separate from the
/// conceal renderer because the two answer different questions — one hides
/// pixels, the other repeats them larger.
public enum MagnifierRenderer {

    public struct Patch: Sendable {
        public let image: CGImage
        public let rect: CGRect
        public let isCircular: Bool
    }

    /// The magnified content and where it belongs, or nil if the source lies
    /// outside the image.
    public static func patch(for body: MagnifierBody, in image: CGImage) -> Patch? {
        let imageBounds = ImageRect(
            x: .zero, y: .zero,
            width: ImagePx(Double(image.width)), height: ImagePx(Double(image.height))
        )
        let source = body.sourceRect.intersection(imageBounds).integralOutward()
            .intersection(imageBounds)
        guard !source.isEmpty, let cropped = image.cropping(to: source.cgRect) else {
            return nil
        }
        return Patch(image: cropped, rect: body.rect.cgRect, isCircular: body.isCircular)
    }
}
