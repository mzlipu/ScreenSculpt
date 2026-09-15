// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import CoreText
import Foundation
import SSGeometry

/// Text layout and drawing via CoreText.
///
/// CoreText rather than AppKit because this module stays headless — no
/// `NSFont`, no `NSAttributedString.draw` — which is what lets the renderer be
/// tested without a window server.
public enum TextRenderer {

    public static func font(size: Double, bold: Bool = true) -> CTFont {
        let name = bold ? "SFPro-Semibold" : "SFPro-Regular"
        let font = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
        return font
    }

    public static func line(
        _ string: String, fontSize: Double, color: CGColor
    ) -> CTLine {
        // CoreText attribute names, not the AppKit ones: `.font` and
        // `.foregroundColor` are declared in AppKit, which this module does not
        // link so that it stays testable without a window server.
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        return CTLineCreateWithAttributedString(attributed)
    }

    public static func measure(_ string: String, fontSize: Double) -> CGSize {
        let line = line(string, fontSize: fontSize, color: CGColor(gray: 0, alpha: 1))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGSize(width: width, height: ascent + descent)
    }

    /// Draw into a **flipped** context — which is what the editor canvas uses,
    /// so text would otherwise render upside-down.
    public static func draw(
        _ string: String, at origin: CGPoint, fontSize: Double,
        color: CGColor, in context: CGContext
    ) {
        let line = line(string, fontSize: fontSize, color: color)
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)

        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: origin.x, y: origin.y + ascent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    public static func draw(
        _ string: String, centeredIn rect: CGRect, fontSize: Double,
        color: CGColor, in context: CGContext
    ) {
        let size = measure(string, fontSize: fontSize)
        draw(
            string,
            at: CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2
            ),
            fontSize: fontSize, color: color, in: context
        )
    }
}

/// A text label, optionally with a pointer tail aimed at its subject.
public struct TextBody: AnnotationBody {
    public static let kind = AnnotationKind.text

    public var text: String
    public var origin: ImagePoint
    /// Where the tail points, if any. Absent means a plain label.
    public var target: ImagePoint?
    public var hasBackground: Bool

    public init(
        text: String, origin: ImagePoint, target: ImagePoint? = nil, hasBackground: Bool = true
    ) {
        self.text = text
        self.origin = origin
        self.target = target
        self.hasBackground = hasBackground
    }

    private static let padding = 10.0

    public func size(style: AnnotationStyle) -> CGSize {
        let measured = TextRenderer.measure(
            text.isEmpty ? " " : text, fontSize: style.fontSize
        )
        return CGSize(
            width: measured.width + Self.padding * 2,
            height: measured.height + Self.padding * 1.4
        )
    }

    public var bounds: ImageRect {
        // Uses the default style's metrics; the renderer re-measures with the
        // real style. Good enough for spatial indexing, which is all this feeds.
        let measured = TextRenderer.measure(text.isEmpty ? " " : text, fontSize: 28)
        return ImageRect(
            x: origin.x, y: origin.y,
            width: ImagePx(measured.width + Self.padding * 2),
            height: ImagePx(measured.height + Self.padding * 1.4)
        )
    }

    public func box(style: AnnotationStyle) -> ImageRect {
        let measured = size(style: style)
        return ImageRect(
            x: origin.x, y: origin.y,
            width: ImagePx(measured.width), height: ImagePx(measured.height)
        )
    }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        var rect = box(style: style)
        if let target {
            rect = rect.union(ImageRect(corner: target, opposite: target))
        }
        return rect.outsetBy(ImagePx(style.strokeWidth * 2 + 6))
    }

    public func handles(style: AnnotationStyle) -> [Handle] {
        var result = [Handle(role: .corner(.topLeft), position: origin)]
        if let target { result.append(Handle(role: .endpoint(false), position: target)) }
        return result
    }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> Self {
        var copy = self
        switch edit.role {
        case .corner: copy.origin = edit.location
        case .endpoint: copy.target = edit.location
        default: break
        }
        return copy
    }

    public func translated(by delta: ImageVector) -> Self {
        var copy = self
        copy.origin = origin + delta
        if let target { copy.target = target + delta }
        return copy
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        if let role = hitHandle(point, tolerance: tolerance, style: style) { return .handle(role) }
        // The whole label rect is grabbable — users expect to click the word,
        // not its outline.
        return box(style: style).outsetBy(tolerance).contains(point) ? .body : nil
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        let rect = box(style: style)

        if let target {
            drawTail(from: rect, to: target, style: style, in: context)
        }

        if hasBackground {
            context.setFillColor(style.color.withAlpha(style.opacity).cgColor)
            let path = CGPath(
                roundedRect: rect.cgRect,
                cornerWidth: 6, cornerHeight: 6, transform: nil
            )
            context.addPath(path)
            context.fillPath()
        }

        TextRenderer.draw(
            text,
            at: CGPoint(
                x: rect.minX.value + Self.padding,
                y: rect.minY.value + Self.padding * 0.7
            ),
            fontSize: style.fontSize,
            color: hasBackground
                ? CGColor(gray: 1, alpha: style.opacity)
                : style.color.withAlpha(style.opacity).cgColor,
            in: context
        )
    }

    /// A tapered tail from the nearest edge of the label to the target.
    private func drawTail(
        from rect: ImageRect, to target: ImagePoint,
        style: AnnotationStyle, in context: CGContext
    ) {
        let anchor = ImagePoint(
            x: ImagePx(min(max(target.x.value, rect.minX.value), rect.maxX.value)),
            y: ImagePx(min(max(target.y.value, rect.minY.value), rect.maxY.value))
        )
        let dx = target.x.value - anchor.x.value
        let dy = target.y.value - anchor.y.value
        let length = hypot(dx, dy)
        guard length > 1 else { return }

        // Perpendicular half-width at the base, so the tail tapers to a point.
        let width = min(max(style.fontSize * 0.28, 5), length / 2)
        let nx = -dy / length * width
        let ny = dx / length * width

        context.setFillColor(style.color.withAlpha(style.opacity).cgColor)
        context.move(to: CGPoint(x: anchor.x.value + nx, y: anchor.y.value + ny))
        context.addLine(to: target.cgPoint)
        context.addLine(to: CGPoint(x: anchor.x.value - nx, y: anchor.y.value - ny))
        context.closePath()
        context.fillPath()
    }
}
