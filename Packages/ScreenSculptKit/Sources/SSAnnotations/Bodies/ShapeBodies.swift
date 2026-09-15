// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

// MARK: - Rectangle

public struct RectangleBody: AnnotationBody {
    public static let kind = AnnotationKind.rectangle

    public var rect: ImageRect
    public var cornerRadius: Double

    public init(rect: ImageRect, cornerRadius: Double = 0) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }

    public var bounds: ImageRect { rect }

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

        // A filled shape is grabbable anywhere inside; an outline only on its
        // edge, so you can still click through the middle of a frame.
        if style.fill != .none, rect.outsetBy(tolerance).contains(point) { return .body }

        let slop = ImagePx(style.strokeWidth / 2) + tolerance
        let outer = rect.outsetBy(slop)
        let inner = rect.insetBy(slop)
        if outer.contains(point) && !inner.contains(point) { return .body }
        return nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        let path = cornerRadius > 0
            ? CGPath(
                roundedRect: rect.cgRect,
                cornerWidth: CGFloat(cornerRadius), cornerHeight: CGFloat(cornerRadius),
                transform: nil
            )
            : CGPath(rect: rect.cgRect, transform: nil)

        if style.fill != .none {
            Draw.applyFill(style, to: context)
            context.addPath(path)
            context.fillPath()
        }
        Draw.applyStroke(style, to: context)
        context.addPath(path)
        context.strokePath()
    }
}

// MARK: - Oval

public struct OvalBody: AnnotationBody {
    public static let kind = AnnotationKind.oval

    public var rect: ImageRect

    public init(rect: ImageRect) { self.rect = rect }

    public var bounds: ImageRect { rect }

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

        // Normalised ellipse distance: 1.0 is exactly on the curve.
        let rx = max(rect.width.value / 2, 0.001)
        let ry = max(rect.height.value / 2, 0.001)
        let nx = (point.x.value - rect.midX.value) / rx
        let ny = (point.y.value - rect.midY.value) / ry
        let distance = sqrt(nx * nx + ny * ny)

        if style.fill != .none, distance <= 1.05 { return .body }

        let band = (style.strokeWidth / 2 + tolerance.value) / min(rx, ry)
        return abs(distance - 1) <= max(band, 0.04) ? .body : nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        let path = CGPath(ellipseIn: rect.cgRect, transform: nil)
        if style.fill != .none {
            Draw.applyFill(style, to: context)
            context.addPath(path)
            context.fillPath()
        }
        Draw.applyStroke(style, to: context)
        context.addPath(path)
        context.strokePath()
    }
}

// MARK: - Line

public struct LineBody: AnnotationBody {
    public static let kind = AnnotationKind.line

    public var start: ImagePoint
    public var end: ImagePoint

    public init(start: ImagePoint, end: ImagePoint) {
        self.start = start
        self.end = end
    }

    public var bounds: ImageRect { ImageRect(corner: start, opposite: end) }

    public func handles(style: AnnotationStyle) -> [Handle] {
        [
            Handle(role: .endpoint(true), position: start),
            Handle(role: .endpoint(false), position: end),
        ]
    }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self {
        var copy = self
        switch edit.role {
        case .endpoint(true):
            copy.start = edit.constrain ? Draw.constrain(edit.location, from: end) : edit.location
        case .endpoint(false):
            copy.end = edit.constrain ? Draw.constrain(edit.location, from: start) : edit.location
        default: break
        }
        return copy
    }

    public func translated(by delta: ImageVector) -> Self {
        LineBody(start: start + delta, end: end + delta)
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        if let role = hitHandle(point, tolerance: tolerance, style: style) { return .handle(role) }
        let slop = style.strokeWidth / 2 + tolerance.value
        return Draw.distance(from: point, toSegment: start, end) <= slop ? .body : nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        Draw.applyStroke(style, to: context)
        context.move(to: start.cgPoint)
        context.addLine(to: end.cgPoint)
        context.strokePath()
    }
}

// MARK: - Shared handle hit-testing

extension AnnotationBody {
    /// Handles win over the body, and are tested with generous slop because at
    /// high zoom they are the only way to reshape an object.
    func hitHandle(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HandleRole? {
        let radius = tolerance.value * 1.5
        for handle in handles(style: style) {
            let dx = point.x.value - handle.position.x.value
            let dy = point.y.value - handle.position.y.value
            if hypot(dx, dy) <= radius { return handle.role }
        }
        return nil
    }
}
