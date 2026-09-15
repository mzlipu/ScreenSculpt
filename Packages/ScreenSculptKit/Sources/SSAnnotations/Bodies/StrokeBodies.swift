// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

// MARK: - Freehand

/// A smoothed pen stroke.
///
/// Raw pointer samples are noisy and numerous, so points are simplified with
/// Ramer–Douglas–Peucker on commit and drawn as a Catmull–Rom spline. Without
/// the simplification a single stroke can carry thousands of points and both
/// hit-testing and serialisation suffer for no visual gain.
public struct FreehandBody: AnnotationBody {
    public static let kind = AnnotationKind.freehand

    public var points: [ImagePoint]

    public init(points: [ImagePoint]) { self.points = points }

    public var bounds: ImageRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(ImageRect(corner: first, opposite: first)) {
            $0.union(ImageRect(corner: $1, opposite: $1))
        }
    }

    public func handles(style: AnnotationStyle) -> [Handle] {
        // Deliberately none. Reshaping a freehand stroke by dragging vertices
        // is fiddly and nobody expects it; move or redraw instead.
        []
    }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self { self }

    public func translated(by delta: ImageVector) -> Self {
        FreehandBody(points: points.map { $0 + delta })
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        let slop = style.strokeWidth / 2 + tolerance.value
        guard points.count > 1 else {
            guard let only = points.first else { return nil }
            return only.distance(to: point).value <= slop ? .body : nil
        }
        let hit = (0..<(points.count - 1)).contains { index in
            Draw.distance(from: point, toSegment: points[index], points[index + 1]) <= slop
        }
        return hit ? .body : nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        guard let first = points.first else { return }
        Draw.applyStroke(style, to: context)

        guard points.count > 2 else {
            context.move(to: first.cgPoint)
            for point in points.dropFirst() { context.addLine(to: point.cgPoint) }
            context.strokePath()
            return
        }

        context.move(to: first.cgPoint)
        // Catmull–Rom through the samples, expressed as cubic Béziers.
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            context.addCurve(
                to: p2.cgPoint,
                control1: CGPoint(
                    x: p1.x.value + (p2.x.value - p0.x.value) / 6,
                    y: p1.y.value + (p2.y.value - p0.y.value) / 6
                ),
                control2: CGPoint(
                    x: p2.x.value - (p3.x.value - p1.x.value) / 6,
                    y: p2.y.value - (p3.y.value - p1.y.value) / 6
                )
            )
        }
        context.strokePath()
    }

    /// Ramer–Douglas–Peucker. `epsilon` is in image pixels.
    public static func simplified(_ points: [ImagePoint], epsilon: Double = 1.2) -> [ImagePoint] {
        guard points.count > 2 else { return points }

        var furthest = 0
        var maxDistance = 0.0
        for index in 1..<(points.count - 1) {
            let distance = Draw.distance(
                from: points[index], toSegment: points[0], points[points.count - 1]
            )
            if distance > maxDistance { maxDistance = distance; furthest = index }
        }

        guard maxDistance > epsilon else { return [points[0], points[points.count - 1]] }
        let left = simplified(Array(points[0...furthest]), epsilon: epsilon)
        let right = simplified(Array(points[furthest...]), epsilon: epsilon)
        return left.dropLast() + right
    }
}

// MARK: - Highlighter

/// A translucent marker stroke.
///
/// Drawn with `.multiply` blending and a square cap, which is what makes it
/// read as ink over the page rather than a semi-transparent line on top of it —
/// overlapping passes darken, exactly like a real highlighter.
public struct HighlighterBody: AnnotationBody {
    public static let kind = AnnotationKind.highlighter

    public var points: [ImagePoint]

    public init(points: [ImagePoint]) { self.points = points }

    public var bounds: ImageRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(ImageRect(corner: first, opposite: first)) {
            $0.union(ImageRect(corner: $1, opposite: $1))
        }
    }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        bounds.outsetBy(ImagePx(style.strokeWidth * 4))
    }

    public func handles(style: AnnotationStyle) -> [Handle] { [] }
    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self { self }

    public func translated(by delta: ImageVector) -> Self {
        HighlighterBody(points: points.map { $0 + delta })
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        let slop = style.strokeWidth * 3 + tolerance.value
        guard points.count > 1 else { return nil }
        let hit = (0..<(points.count - 1)).contains { index in
            Draw.distance(from: point, toSegment: points[index], points[index + 1]) <= slop
        }
        return hit ? .body : nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        guard let first = points.first else { return }
        context.saveGState()
        context.setBlendMode(.multiply)
        context.setStrokeColor(style.color.withAlpha(0.38 * style.opacity).cgColor)
        context.setLineWidth(CGFloat(style.strokeWidth * 6))
        // Square caps: a highlighter has a flat chisel tip, not a round one.
        context.setLineCap(.square)
        context.setLineJoin(.round)
        context.move(to: first.cgPoint)
        for point in points.dropFirst() { context.addLine(to: point.cgPoint) }
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Counter

/// A numbered badge for step-by-step walkthroughs.
public struct CounterBody: AnnotationBody {
    public static let kind = AnnotationKind.counter

    public var center: ImagePoint
    public var number: Int

    public init(center: ImagePoint, number: Int) {
        self.center = center
        self.number = number
    }

    public func radius(style: AnnotationStyle) -> Double { max(style.fontSize * 0.9, 14) }

    public var bounds: ImageRect {
        let r = 26.0
        return ImageRect(
            x: center.x - ImagePx(r), y: center.y - ImagePx(r),
            width: ImagePx(r * 2), height: ImagePx(r * 2)
        )
    }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        let r = radius(style: style) + style.strokeWidth + 4
        return ImageRect(
            x: center.x - ImagePx(r), y: center.y - ImagePx(r),
            width: ImagePx(r * 2), height: ImagePx(r * 2)
        )
    }

    public func handles(style: AnnotationStyle) -> [Handle] { [] }
    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self { self }

    public func translated(by delta: ImageVector) -> Self {
        CounterBody(center: center + delta, number: number)
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        center.distance(to: point).value <= radius(style: style) + tolerance.value ? .body : nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        let r = radius(style: style)
        let circle = CGRect(
            x: center.x.value - r, y: center.y.value - r, width: r * 2, height: r * 2
        )

        context.setFillColor(style.color.withAlpha(style.opacity).cgColor)
        context.fillEllipse(in: circle)

        // A white ring keeps the badge legible on any background.
        context.setStrokeColor(CGColor(gray: 1, alpha: style.opacity))
        context.setLineWidth(CGFloat(max(style.strokeWidth * 0.5, 2)))
        context.setLineDash(phase: 0, lengths: [])
        context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))

        TextRenderer.draw(
            "\(number)",
            centeredIn: circle,
            fontSize: r * 1.15,
            color: CGColor(gray: 1, alpha: style.opacity),
            in: context
        )
    }
}
