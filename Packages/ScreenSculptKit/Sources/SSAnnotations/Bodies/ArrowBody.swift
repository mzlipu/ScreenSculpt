// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

/// An arrow, optionally bent into an arc.
///
/// `bend` is a signed fraction of the shaft length describing how far the
/// midpoint is pushed perpendicular to it. Storing curvature that way rather
/// than as an absolute control point means the curve keeps its shape when the
/// arrow is lengthened or moved.
public struct ArrowBody: AnnotationBody {
    public static let kind = AnnotationKind.arrow

    public var start: ImagePoint
    public var end: ImagePoint
    public var bend: Double
    public var doubleHeaded: Bool

    public init(
        start: ImagePoint, end: ImagePoint, bend: Double = 0, doubleHeaded: Bool = false
    ) {
        self.start = start
        self.end = end
        self.bend = bend
        self.doubleHeaded = doubleHeaded
    }

    public var bounds: ImageRect {
        // Include the control point, or a strongly bent arrow clips.
        ImageRect(corner: start, opposite: end).union(
            ImageRect(corner: controlPoint, opposite: controlPoint)
        )
    }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        bounds.outsetBy(ImagePx(headLength(style: style) + style.strokeWidth * 2))
    }

    private var midpoint: ImagePoint {
        ImagePoint(
            x: ImagePx((start.x.value + end.x.value) / 2),
            y: ImagePx((start.y.value + end.y.value) / 2)
        )
    }

    private var shaftLength: Double {
        hypot(end.x.value - start.x.value, end.y.value - start.y.value)
    }

    /// Quadratic control point implied by `bend`.
    var controlPoint: ImagePoint {
        guard bend != 0, shaftLength > 0 else { return midpoint }
        let dx = end.x.value - start.x.value
        let dy = end.y.value - start.y.value
        // Perpendicular, normalised, scaled by the bend fraction. Doubled
        // because a quadratic curve reaches only half way to its control point.
        let nx = -dy / shaftLength
        let ny = dx / shaftLength
        let offset = bend * shaftLength * 2
        return ImagePoint(
            x: ImagePx(midpoint.x.value + nx * offset),
            y: ImagePx(midpoint.y.value + ny * offset)
        )
    }

    private func headLength(style: AnnotationStyle) -> Double {
        // Grows with weight but tapers off, so a long thin arrow does not end
        // in a comically large head.
        min(style.strokeWidth * 4.5, max(shaftLength * 0.28, style.strokeWidth * 2.5))
    }

    public func handles(style: AnnotationStyle) -> [Handle] {
        [
            Handle(role: .endpoint(true), position: start),
            Handle(role: .endpoint(false), position: end),
            Handle(role: .bend, position: curvePoint(at: 0.5)),
        ]
    }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self {
        var copy = self
        switch edit.role {
        case .endpoint(true):
            copy.start = edit.constrain ? Draw.constrain(edit.location, from: end) : edit.location
        case .endpoint(false):
            copy.end = edit.constrain ? Draw.constrain(edit.location, from: start) : edit.location
        case .bend:
            copy.bend = bendFraction(for: edit.location)
        default: break
        }
        return copy
    }

    /// Signed perpendicular offset of `point` from the shaft, as a fraction.
    private func bendFraction(for point: ImagePoint) -> Double {
        guard shaftLength > 0 else { return 0 }
        let dx = end.x.value - start.x.value
        let dy = end.y.value - start.y.value
        let nx = -dy / shaftLength
        let ny = dx / shaftLength
        let offsetX = point.x.value - midpoint.x.value
        let offsetY = point.y.value - midpoint.y.value
        let signed = offsetX * nx + offsetY * ny
        // The handle sits on the curve, which is half way to the control point.
        return max(-0.9, min(0.9, signed / shaftLength))
    }

    public func translated(by delta: ImageVector) -> Self {
        var copy = self
        copy.start = start + delta
        copy.end = end + delta
        return copy
    }

    /// Point on the quadratic curve at parameter `t`.
    func curvePoint(at t: Double) -> ImagePoint {
        guard bend != 0 else {
            return ImagePoint(
                x: ImagePx(start.x.value + (end.x.value - start.x.value) * t),
                y: ImagePx(start.y.value + (end.y.value - start.y.value) * t)
            )
        }
        let control = controlPoint
        let inv = 1 - t
        let x = inv * inv * start.x.value
            + 2 * inv * t * control.x.value
            + t * t * end.x.value
        let y = inv * inv * start.y.value
            + 2 * inv * t * control.y.value
            + t * t * end.y.value
        return ImagePoint(x: ImagePx(x), y: ImagePx(y))
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        if let role = hitHandle(point, tolerance: tolerance, style: style) { return .handle(role) }
        let slop = style.strokeWidth / 2 + tolerance.value + headLength(style: style) * 0.2

        // Sample the curve rather than solving it — 16 segments is well under
        // the tolerance for any arrow a person can draw.
        var previous = curvePoint(at: 0)
        for step in 1...16 {
            let next = curvePoint(at: Double(step) / 16)
            if Draw.distance(from: point, toSegment: previous, next) <= slop { return .body }
            previous = next
        }
        return nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        let head = headLength(style: style)
        Draw.applyStroke(style, to: context)
        // A dashed arrow shaft reads as broken rather than styled.
        context.setLineDash(phase: 0, lengths: [])

        // Stop the shaft short of the head so the point stays sharp instead of
        // being blunted by the round line cap underneath it.
        let shaftEnd = curvePoint(at: max(0, 1 - head * 0.55 / max(shaftLength, 1)))
        let shaftStart = doubleHeaded
            ? curvePoint(at: min(1, head * 0.55 / max(shaftLength, 1)))
            : start

        context.move(to: shaftStart.cgPoint)
        if bend != 0 {
            context.addQuadCurve(to: shaftEnd.cgPoint, control: controlPoint.cgPoint)
        } else {
            context.addLine(to: shaftEnd.cgPoint)
        }
        context.strokePath()

        drawHead(at: end, from: curvePoint(at: 0.92), length: head, style: style, in: context)
        if doubleHeaded {
            drawHead(
                at: start, from: curvePoint(at: 0.08), length: head, style: style, in: context
            )
        }
    }

    private func drawHead(
        at tip: ImagePoint, from approach: ImagePoint,
        length: Double, style: AnnotationStyle, in context: CGContext
    ) {
        let angle = atan2(tip.y.value - approach.y.value, tip.x.value - approach.x.value)
        let spread = 0.42
        context.setFillColor(style.color.withAlpha(style.color.a * style.opacity).cgColor)
        context.move(to: tip.cgPoint)
        context.addLine(to: CGPoint(
            x: tip.x.value - cos(angle - spread) * length,
            y: tip.y.value - sin(angle - spread) * length
        ))
        // Notch the back edge so the head reads as an arrow rather than a
        // triangle stuck on the end of a line.
        context.addLine(to: CGPoint(
            x: tip.x.value - cos(angle) * length * 0.72,
            y: tip.y.value - sin(angle) * length * 0.72
        ))
        context.addLine(to: CGPoint(
            x: tip.x.value - cos(angle + spread) * length,
            y: tip.y.value - sin(angle + spread) * length
        ))
        context.closePath()
        context.fillPath()
    }
}
