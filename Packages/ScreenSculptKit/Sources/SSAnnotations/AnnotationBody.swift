// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

/// Context a body needs while drawing.
public struct RenderContext: Sendable {
    /// Scale of the image being drawn into, so stroke weights match the capture.
    public let pixelScale: PixelScale
    /// True when rendering for export — suppresses anything that is editing
    /// affordance rather than content.
    public let isExport: Bool

    public init(pixelScale: PixelScale, isExport: Bool) {
        self.pixelScale = pixelScale
        self.isExport = isExport
    }
}

/// One kind of annotation.
///
/// Conformers are **structs**, which is what makes undo a snapshot copy rather
/// than a log of inverse operations — the usual source of "undo left the
/// document in an impossible state" bugs in editors like this.
///
/// Every method is pure: `applying` returns a new body, never mutates. The
/// caller decides when to commit.
public protocol AnnotationBody: Codable, Sendable, Equatable {
    static var kind: AnnotationKind { get }

    /// Tight geometric bounds, excluding stroke and decoration.
    var bounds: ImageRect { get }

    /// Bounds inflated for invalidation: stroke width, arrowheads, text ascent.
    /// Too small and you get trails; too large and redraws get expensive.
    func dirtyBounds(style: AnnotationStyle) -> ImageRect

    /// Editing handles. Order must be stable across edits, or a drag jumps to
    /// a different handle mid-gesture.
    func handles(style: AnnotationStyle) -> [Handle]

    /// Move one handle. Pure.
    func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self

    /// Rigid translation. Separate from `applying` because it is the drag hot
    /// path and should not go through handle dispatch.
    func translated(by delta: ImageVector) -> Self

    /// `tolerance` arrives already converted from view points, so hit slop is
    /// constant on screen at any zoom.
    func hitTest(_ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle) -> HitResult?

    /// Draw into a context whose CTM is already image-pixel space.
    /// Must not read global state and must not touch AppKit.
    func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext)

    /// Edges this body offers as alignment targets for others.
    func snapCandidates(id: AnnotationID) -> [SnapCandidate]
}

// MARK: - Shared geometry helpers

extension AnnotationBody {
    /// Default snap targets: the four edges and the centre of `bounds`.
    public func snapCandidates(id: AnnotationID) -> [SnapCandidate] {
        let box = bounds
        return [
            SnapCandidate(axis: .vertical, position: box.minX, owner: id),
            SnapCandidate(axis: .vertical, position: box.midX, owner: id),
            SnapCandidate(axis: .vertical, position: box.maxX, owner: id),
            SnapCandidate(axis: .horizontal, position: box.minY, owner: id),
            SnapCandidate(axis: .horizontal, position: box.midY, owner: id),
            SnapCandidate(axis: .horizontal, position: box.maxY, owner: id),
        ]
    }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        bounds.outsetBy(ImagePx(style.strokeWidth * 2 + 4))
    }
}

// MARK: - Drawing utilities

enum Draw {
    /// Apply stroke attributes shared by every body.
    static func applyStroke(_ style: AnnotationStyle, to context: CGContext) {
        context.setStrokeColor(style.color.withAlpha(style.color.a * style.opacity).cgColor)
        context.setLineWidth(CGFloat(style.strokeWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if let pattern = style.dash.pattern(width: style.strokeWidth) {
            context.setLineDash(phase: 0, lengths: pattern)
        } else {
            context.setLineDash(phase: 0, lengths: [])
        }
    }

    static func applyFill(_ style: AnnotationStyle, to context: CGContext) {
        let alpha = style.fill.alpha * style.opacity
        context.setFillColor(style.color.withAlpha(alpha).cgColor)
    }

    /// Distance from `point` to the segment a→b, for hit-testing open shapes.
    static func distance(
        from point: ImagePoint, toSegment a: ImagePoint, _ b: ImagePoint
    ) -> Double {
        let px = point.x.value, py = point.y.value
        let ax = a.x.value, ay = a.y.value
        let bx = b.x.value, by = b.y.value
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(px - ax, py - ay) }
        // Projection parameter, clamped so we measure to the segment rather
        // than the infinite line.
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }

    /// Constrain b relative to a to the nearest 45°, for Shift-drag.
    static func constrain(_ b: ImagePoint, from a: ImagePoint) -> ImagePoint {
        let dx = b.x.value - a.x.value
        let dy = b.y.value - a.y.value
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return ImagePoint(
            x: ImagePx(a.x.value + cos(angle) * length),
            y: ImagePx(a.y.value + sin(angle) * length)
        )
    }

    /// Square off a rect from its anchor, for Shift-drag on box shapes.
    static func square(_ rect: ImageRect, anchoredAt anchor: ImagePoint) -> ImageRect {
        let side = max(rect.width.value, rect.height.value)
        let toRight = rect.minX.value >= anchor.x.value - 0.001
        let toBottom = rect.minY.value >= anchor.y.value - 0.001
        return ImageRect(
            x: ImagePx(toRight ? anchor.x.value : anchor.x.value - side),
            y: ImagePx(toBottom ? anchor.y.value : anchor.y.value - side),
            width: ImagePx(side), height: ImagePx(side)
        )
    }

    static func corners(of rect: ImageRect) -> [Handle] {
        [
            Handle(role: .corner(.topLeft), position: ImagePoint(x: rect.minX, y: rect.minY)),
            Handle(role: .corner(.topRight), position: ImagePoint(x: rect.maxX, y: rect.minY)),
            Handle(role: .corner(.bottomLeft), position: ImagePoint(x: rect.minX, y: rect.maxY)),
            Handle(
                role: .corner(.bottomRight), position: ImagePoint(x: rect.maxX, y: rect.maxY)
            ),
        ]
    }

    /// Resize `rect` by moving one corner, keeping the opposite one fixed.
    static func resize(
        _ rect: ImageRect, corner: HandleRole.Corner, to point: ImagePoint, square: Bool
    ) -> ImageRect {
        let fixed: ImagePoint = switch corner {
        case .topLeft: ImagePoint(x: rect.maxX, y: rect.maxY)
        case .topRight: ImagePoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: ImagePoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: ImagePoint(x: rect.minX, y: rect.minY)
        }
        let updated = ImageRect(corner: fixed, opposite: point)
        return square ? Draw.square(updated, anchoredAt: fixed) : updated
    }
}
