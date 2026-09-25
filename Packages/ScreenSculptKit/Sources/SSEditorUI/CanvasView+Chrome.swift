// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSDocument
import SSGeometry
import SSImaging

/// Selection marquee, handles, pixel grid and the size readout.
///
/// All of it is drawn in **view points**, never image pixels, so a handle
/// stays 9pt and the marquee stays one pixel wide whether the canvas is at
/// 25% or 3200%.
extension CanvasView {

    // MARK: - Chrome
    //
    // Drawn in view points at a fixed size, so handles stay grabbable and the
    // marquee stays one pixel wide at every zoom level.

    /// Draw every piece of chrome.
    ///
    /// Called by ``ChromeOverlayView`` rather than from this view's own
    /// `draw(_:)`. It cannot be drawn here: the captured image lives in a
    /// sublayer, and Core Animation composites sublayers above their
    /// superlayer's own content — so anything this view painted itself would
    /// sit underneath the screenshot and never be seen.
    func drawChrome(in context: CGContext) {
        if transform.pixelGridAlpha > 0 { drawPixelGrid(in: context) }

        drawSnapGuides(in: context)
        drawAnnotationSelection(in: context)

        guard let selection else { return }
        let rect = transform.toCanvas(selection).cgRect

        context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addRect(bounds)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))

        let knob = Self.handleSide
        context.setFillColor(NSColor.white.cgColor)
        for point in [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ] {
            context.fillEllipse(in: CGRect(
                x: point.x - knob / 2, y: point.y - knob / 2, width: knob, height: knob
            ))
        }

        drawSizeLabel(for: selection, at: rect, in: context)
    }

    /// One hairline per image pixel, faded in above 16× so it does not pop.
    ///
    /// This is what makes extreme zoom genuinely useful rather than merely
    /// possible.
    func drawPixelGrid(in context: CGContext) {
        let alpha = transform.pixelGridAlpha
        let step = transform.toCanvas(ImagePx(1)).cgFloat
        guard step >= 4 else { return }

        context.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
        context.setLineWidth(1 / (window?.backingScaleFactor ?? 2))
        context.beginPath()

        let firstX = transform.toCanvas(
            ImagePoint(x: ImagePx(transform.imageOrigin.x.value.rounded(.up)), y: .zero)
        ).x.cgFloat
        var x = firstX
        while x < bounds.maxX {
            context.move(to: CGPoint(x: x, y: bounds.minY))
            context.addLine(to: CGPoint(x: x, y: bounds.maxY))
            x += step
        }

        let firstY = transform.toCanvas(
            ImagePoint(x: .zero, y: ImagePx(transform.imageOrigin.y.value.rounded(.up)))
        ).y.cgFloat
        var y = firstY
        while y < bounds.maxY {
            context.move(to: CGPoint(x: bounds.minX, y: y))
            context.addLine(to: CGPoint(x: bounds.maxX, y: y))
            y += step
        }
        context.strokePath()
    }

    /// The dimensions of a selection, in pixels and — on a retina capture —
    /// points as well.
    func sizeLabelText(for rect: ImageRect) -> String {
        let scale = image.pixelScale
        let pixels = "\(Int(rect.width.value)) × \(Int(rect.height.value)) px"
        guard scale.isRetina else { return pixels }
        let points = "\(Int(rect.width.inPoints(scale).value)) × "
            + "\(Int(rect.height.inPoints(scale).value)) pt"
        return "\(pixels)   \(points)"
    }

    func drawSizeLabel(for rect: ImageRect, at canvas: CGRect, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: sizeLabelText(for: rect), attributes: attributes)
        let size = string.size()

        // While dragging, sit beside the pointer. Otherwise anchor to the
        // top-left of the finished selection, where it is out of the way.
        var origin: CGPoint
        if isDraggingSelection, let cursor = selectionCursor {
            let point = transform.toCanvas(cursor).cgPoint
            origin = CGPoint(x: point.x + 14, y: point.y + 14)
            // Flip to the other side of the pointer near an edge, rather than
            // letting the readout run off the view.
            if origin.x + size.width + 10 > bounds.maxX {
                origin.x = point.x - size.width - 22
            }
            if origin.y + size.height + 8 > bounds.maxY {
                origin.y = point.y - size.height - 20
            }
        } else {
            origin = CGPoint(x: canvas.minX, y: canvas.minY - size.height - 8)
            if origin.y < 2 { origin.y = canvas.maxY + 8 }
        }
        origin.x = min(max(origin.x, 2), bounds.maxX - size.width - 10)
        origin.y = min(max(origin.y, 2), bounds.maxY - size.height - 6)

        let box = CGRect(
            x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.82).cgColor)
        context.addPath(CGPath(
            roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil
        ))
        context.fillPath()
        string.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
    }
}

// MARK: - Annotation chrome

extension CanvasView {

    /// Outline and handles for the selected annotation.
    ///
    /// Drawn in view points at a fixed size — a handle must stay grabbable at
    /// 25% and must not swell to cover the object at 3200%.
    func drawAnnotationSelection(in context: CGContext) {
        guard let selected = store?.selectedAnnotation else { return }

        let box = transform.toCanvas(selected.bounds).cgRect.insetBy(dx: -3, dy: -3)
        context.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(box)
        context.setLineDash(phase: 0, lengths: [])

        for handle in selected.handles() {
            let point = transform.toCanvas(handle.position).cgPoint
            let side: CGFloat = Self.handleSide
            let rect = CGRect(
                x: point.x - side / 2, y: point.y - side / 2, width: side, height: side
            )
            // A bend handle is round so it reads differently from the endpoints
            // it sits between.
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5)
            if case .bend = handle.role {
                context.fillEllipse(in: rect)
                context.strokeEllipse(in: rect)
            } else {
                context.fill(rect)
                context.stroke(rect)
            }
        }
    }

    /// Alignment guides, shown only while they are actually snapping.
    func drawSnapGuides(in context: CGContext) {
        guard let engine = snapEngine else { return }
        context.setStrokeColor(NSColor.systemPink.withAlphaComponent(0.85).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.beginPath()
        if let x = engine.activeVertical {
            let canvasX = transform.toCanvas(ImagePoint(x: x, y: .zero)).x.cgFloat
            context.move(to: CGPoint(x: canvasX, y: bounds.minY))
            context.addLine(to: CGPoint(x: canvasX, y: bounds.maxY))
        }
        if let y = engine.activeHorizontal {
            let canvasY = transform.toCanvas(ImagePoint(x: .zero, y: y)).y.cgFloat
            context.move(to: CGPoint(x: bounds.minX, y: canvasY))
            context.addLine(to: CGPoint(x: bounds.maxX, y: canvasY))
        }
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }
}
