// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSDocument
import SSGeometry
import SSImaging

/// Mouse, trackpad and keyboard handling for the canvas.
///
/// Separated from the view's own setup because input is where most of the
/// behaviour lives, and mixing it with layer plumbing made both harder to
/// read.
extension CanvasView {

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = imagePoint(from: event)
        if spaceHeld {
            beginPan(event)
            return
        }
        anchor = point
        isDraggingSelection = true
        selection = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning { continuePan(event); return }
        guard isDraggingSelection, let anchor else { return }

        var current = imagePoint(from: event)
        if event.modifierFlags.contains(.shift) {
            let side = max(
                abs(current.x.value - anchor.x.value), abs(current.y.value - anchor.y.value)
            )
            current = ImagePoint(
                x: ImagePx(anchor.x.value + (current.x < anchor.x ? -side : side)),
                y: ImagePx(anchor.y.value + (current.y < anchor.y ? -side : side))
            )
        }

        let rect = ImageRect(corner: anchor, opposite: current)
            .intersection(ImageRect(size: image.size))
        selection = rect.isEmpty ? nil : rect.integralOutward()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning { endPan(); return }
        isDraggingSelection = false
        anchor = nil
        onSelectionChanged?(selection)
    }

    /// Right-drag pans, matching the convention in image editors.
    override func rightMouseDown(with event: NSEvent) { beginPan(event) }
    override func rightMouseDragged(with event: NSEvent) { continuePan(event) }
    override func rightMouseUp(with event: NSEvent) { endPan() }

    func beginPan(_ event: NSEvent) {
        isPanning = true
        panOrigin = (event.locationInWindow, transform.imageOrigin)
        NSCursor.closedHand.push()
    }

    func continuePan(_ event: NSEvent) {
        guard isPanning, let panOrigin else { return }
        let dx = event.locationInWindow.x - panOrigin.mouse.x
        let dy = event.locationInWindow.y - panOrigin.mouse.y
        let scale = transform.backingScale.value / transform.zoom
        setTransform(transform.with(imageOrigin: ImagePoint(
            x: ImagePx(panOrigin.imageOrigin.x.value - Double(dx) * scale),
            // The view is flipped, so a downward drag moves content the other way.
            y: ImagePx(panOrigin.imageOrigin.y.value + Double(dy) * scale)
        )))
    }

    func endPan() {
        guard isPanning else { return }
        isPanning = false
        panOrigin = nil
        NSCursor.pop()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1 + Double(event.scrollingDeltaY) * 0.01
            let cursor = CanvasPoint(cgPoint: convert(event.locationInWindow, from: nil))
            setTransform(transform.zoomed(to: transform.zoom * factor, anchoredAt: cursor))
        } else {
            let scale = transform.backingScale.value / transform.zoom
            setTransform(transform.with(imageOrigin: ImagePoint(
                x: ImagePx(transform.imageOrigin.x.value - Double(event.scrollingDeltaX) * scale),
                y: ImagePx(transform.imageOrigin.y.value - Double(event.scrollingDeltaY) * scale)
            )))
        }
    }

    override func magnify(with event: NSEvent) {
        let cursor = CanvasPoint(cgPoint: convert(event.locationInWindow, from: nil))
        setTransform(transform.zoomed(
            to: transform.zoom * (1 + Double(event.magnification)), anchoredAt: cursor
        ))
    }

    override func keyDown(with event: NSEvent) {
        // Space-drag panning, Photoshop style.
        if event.keyCode == 49 { spaceHeld = true; NSCursor.openHand.push(); return }

        guard let characters = event.charactersIgnoringModifiers else {
            return super.keyDown(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        let command = event.modifierFlags.contains(.command)
        let step = ImagePx(shift ? 10 : 1)

        switch characters {
        case "\r": onCommitCrop?()
        case "\u{1b}": selection = nil; needsDisplay = true; onSelectionChanged?(nil)
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): nudge(dy: -step, resize: command)
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): nudge(dy: step, resize: command)
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): nudge(dx: -step, resize: command)
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): nudge(dx: step, resize: command)
        case "[": growSelection(by: -(shift ? 10 : 1))
        case "]": growSelection(by: shift ? 10 : 1)
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49, spaceHeld {
            spaceHeld = false
            NSCursor.pop()
            return
        }
        super.keyUp(with: event)
    }

    func nudge(dx: ImagePx = .zero, dy: ImagePx = .zero, resize: Bool) {
        guard let current = selection else { return }
        let updated: ImageRect
        if resize {
            updated = ImageRect(
                origin: current.origin,
                size: ImageSize(width: current.width + dx, height: current.height + dy)
            )
        } else {
            updated = current.offsetBy(ImageVector(dx: dx, dy: dy))
        }
        selection = updated.intersection(ImageRect(size: image.size))
        needsDisplay = true
        onSelectionChanged?(selection)
    }

    func growSelection(by amount: Double) {
        guard let current = selection else { return }
        selection = current.outsetBy(ImagePx(amount))
            .intersection(ImageRect(size: image.size))
        needsDisplay = true
        onSelectionChanged?(selection)
    }

    func imagePoint(from event: NSEvent) -> ImagePoint {
        transform.toImage(CanvasPoint(cgPoint: convert(event.locationInWindow, from: nil)))
    }
}
