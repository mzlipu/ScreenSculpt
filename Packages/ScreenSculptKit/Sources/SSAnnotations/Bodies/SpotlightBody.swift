// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

/// Darkens everything except one region.
///
/// The inverse of most annotations: the mark is the *absence* of the effect.
/// Drawn as a single even-odd fill covering the whole canvas with the region
/// punched out, so the dimming is one uniform layer rather than four rectangles
/// that would seam visibly where they meet.
public struct SpotlightBody: AnnotationBody {
    public static let kind = AnnotationKind.spotlight

    public enum Shape: String, Codable, Sendable, CaseIterable, Identifiable {
        case rectangle, ellipse
        public var id: String { rawValue }
        public var label: String { self == .rectangle ? "Rectangle" : "Ellipse" }
    }

    public var rect: ImageRect
    public var shape: Shape
    /// How dark the surroundings become, 0…1.
    public var dimming: Double

    public init(rect: ImageRect, shape: Shape = .rectangle, dimming: Double = 0.62) {
        self.rect = rect
        self.shape = shape
        self.dimming = dimming
    }

    public var bounds: ImageRect { rect }

    /// The whole canvas is affected, but invalidating all of it on every drag
    /// would be needlessly expensive — the renderer redraws the dim layer
    /// anyway when anything in it moves.
    public func dirtyBounds(style: AnnotationStyle) -> ImageRect { rect.outsetBy(8) }

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

    /// Grabbable by its lit region. Clicking the dimmed area selects whatever
    /// is under it, which is what someone reaching past a spotlight expects.
    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        if let role = hitHandle(point, tolerance: tolerance, style: style) { return .handle(role) }
        return rect.outsetBy(tolerance).contains(point) ? .body : nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        let canvas = render.imageBounds.isEmpty ? rect.outsetBy(10_000) : render.imageBounds
        let hole = CGMutablePath()
        switch shape {
        case .rectangle: hole.addRect(rect.cgRect)
        case .ellipse: hole.addEllipse(in: rect.cgRect)
        }

        let path = CGMutablePath()
        path.addRect(canvas.cgRect)
        path.addPath(hole)

        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: max(0, min(1, dimming))))
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        context.restoreGState()

        // A thin edge on export too: without it the lit region has no boundary
        // on light content and the effect reads as a printing fault.
        Draw.applyStroke(style, to: context)
        context.setLineWidth(max(1, style.strokeWidth / 2))
        context.addPath(hole)
        context.strokePath()
    }
}

/// A measured line, with the distance written alongside it.
///
/// Distinct from the live ruler in the measurement tools: this one is part of
/// the document. It is what you use to leave the measurement *in* the image
/// for someone else to read.
public struct RulerBody: AnnotationBody {
    public static let kind = AnnotationKind.ruler

    public enum Unit: String, Codable, Sendable, CaseIterable, Identifiable {
        case pixels, points
        public var id: String { rawValue }
        public var label: String { self == .pixels ? "Pixels" : "Points" }
        public var suffix: String { self == .pixels ? "px" : "pt" }
    }

    public var start: ImagePoint
    public var end: ImagePoint
    public var unit: Unit

    public init(start: ImagePoint, end: ImagePoint, unit: Unit = .pixels) {
        self.start = start
        self.end = end
        self.unit = unit
    }

    public var bounds: ImageRect { ImageRect(corner: start, opposite: end) }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        bounds.outsetBy(ImagePx(style.strokeWidth * 2 + style.fontSize + 16))
    }

    public func handles(style: AnnotationStyle) -> [Handle] {
        [
            Handle(role: .endpoint(true), position: start),
            Handle(role: .endpoint(false), position: end),
        ]
    }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self {
        guard case .endpoint(let isStart) = edit.role else { return self }
        var copy = self
        let anchor = isStart ? end : start
        let moved = edit.constrain ? Draw.constrain(edit.location, from: anchor) : edit.location
        if isStart { copy.start = moved } else { copy.end = moved }
        return copy
    }

    public func translated(by delta: ImageVector) -> Self {
        var copy = self
        copy.start = start + delta
        copy.end = end + delta
        return copy
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        if let role = hitHandle(point, tolerance: tolerance, style: style) { return .handle(role) }
        let slop = ImagePx(style.strokeWidth / 2) + tolerance
        return Draw.distance(from: point, toSegment: start, end) <= slop.value ? .body : nil
    }

    /// Length in the requested unit.
    ///
    /// Points come from the capture's own scale, frozen at capture time — not
    /// from whichever display the editor happens to be on, which would make the
    /// same ruler read differently after dragging the window.
    public func measurement(scale: PixelScale) -> String {
        let pixels = start.distance(to: end)
        let value = unit == .pixels ? pixels.value : scale.points(pixels).value
        return "\(Int(value.rounded())) \(unit.suffix)"
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        Draw.applyStroke(style, to: context)
        context.setLineDash(phase: 0, lengths: [])

        // End caps perpendicular to the line, the way a dimension line is drawn
        // on a technical drawing — an arrowhead would suggest direction, and a
        // measurement has none.
        let dx = end.x.value - start.x.value
        let dy = end.y.value - start.y.value
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0.5 else { return }
        let nx = -dy / length, ny = dx / length
        let cap = max(6, style.strokeWidth * 2.5)

        context.move(to: start.cgPoint)
        context.addLine(to: end.cgPoint)
        for point in [start, end] {
            context.move(to: CGPoint(x: point.x.value - nx * cap, y: point.y.value - ny * cap))
            context.addLine(to: CGPoint(x: point.x.value + nx * cap, y: point.y.value + ny * cap))
        }
        context.strokePath()

        // The label sits off the line on its normal, so it never lies on top of
        // what is being measured.
        let text = measurement(scale: render.pixelScale)
        let size = TextRenderer.measure(text, fontSize: style.fontSize)
        let offset = cap + style.fontSize * 0.6
        let anchor = CGPoint(
            x: (start.x.value + end.x.value) / 2 + nx * offset - size.width / 2,
            y: (start.y.value + end.y.value) / 2 + ny * offset - size.height / 2
        )

        // A backing plate, because a measurement written straight onto a
        // screenshot is unreadable as often as not.
        let plate = CGRect(
            x: anchor.x - 6, y: anchor.y - 3,
            width: size.width + 12, height: size.height + 6
        )
        context.setFillColor(CGColor(gray: 0, alpha: 0.65 * style.opacity))
        context.addPath(CGPath(roundedRect: plate, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()

        TextRenderer.draw(
            text, at: anchor, fontSize: style.fontSize,
            color: CGColor(gray: 1, alpha: style.opacity), in: context
        )
    }
}
