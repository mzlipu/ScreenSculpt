// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSAnnotations
import SSDocument
import SSMeasure
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

        // A field open on screen commits before anything else happens.
        if textEditor.isEditing { textEditor.finish(); return }

        // Double-clicking an existing label re-opens it for editing.
        if event.clickCount == 2, tools?.tool == .select,
           let hit = store?.annotations.hitTest(point, tolerance: hitTolerance),
           hit.0.kind == .text {
            store?.select(hit.0.id)
            beginEditingText(hit.0)
            return
        }

        // Annotations get first refusal. Only when nothing is hit — and the
        // select tool is active — does the drag become a crop marquee.
        if let tools, tools.begin(
            at: point, tolerance: hitTolerance, modifiers: event.modifierFlags
        ) {
            // The text tool places a label and immediately opens it for typing;
            // without this the tool produces an empty box and no way to fill it.
            if let placed = store?.selectedAnnotation, placed.kind == .text {
                refreshAnnotations()
                beginEditingText(placed)
                return
            }
            beginSnapping()
            refreshAnnotations()
            needsDisplay = true
            return
        }

        anchor = point
        isDraggingSelection = true
        selection = nil
        refreshAnnotations()
        needsDisplay = true
    }

    /// Gather snap candidates once, at drag start.
    private func beginSnapping() {
        guard let store, let tools else { return }
        snapEngine = SnapEngine(
            candidates: store.annotations.snapCandidates(excluding: tools.activeAnnotation),
            canvasBounds: ImageRect(size: store.size),
            // A fixed 7pt on screen, so snapping feels identical at any zoom.
            threshold: transform.toImage(ViewPt(7))
        )
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning { continuePan(event); return }

        if let tools, tools.gestureIsActive {
            tools.drag(
                to: imagePoint(from: event),
                modifiers: event.modifierFlags,
                snap: &snapEngine
            )
            refreshAnnotations()
            needsDisplay = true
            return
        }

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

    /// Live colour readout needs the pointer position, which the canvas did not
    /// previously track at all.
    override func mouseMoved(with event: NSEvent) {
        measurement?.updateHover(at: imagePoint(from: event))
        onMeasurementChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        measurement?.clearHover()
        onMeasurementChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning { endPan(); return }

        if let tools, tools.gestureIsActive {
            tools.end()
            snapEngine = nil
            onAnnotationsChanged?()
            refreshAnnotations()
            needsDisplay = true
            return
        }

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
        case "\u{1b}": handleEscape()
        case String(UnicodeScalar(NSDeleteCharacter)!), "\u{7f}": handleDelete()
        case "[": growSelection(by: -(shift ? 10 : 1))
        case "]": growSelection(by: shift ? 10 : 1)
        default:
            if handleArrowKey(characters, step: step, resize: command) { return }
            if !handleMeasurementKey(characters, event: event) { super.keyDown(with: event) }
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

// MARK: - Key handling detail

extension CanvasView {

    /// Escape unwinds one level at a time: cancel a draw, then deselect an
    /// object, then clear the marquee. Doing all three at once loses work.
    func handleEscape() {
        if let tools, tools.gestureIsActive {
            tools.cancel()
            snapEngine = nil
            refreshAnnotations()
        } else if store?.selectedAnnotation != nil {
            store?.select(nil)
            refreshAnnotations()
        } else {
            selection = nil
            onSelectionChanged?(nil)
        }
        needsDisplay = true
    }

    func handleDelete() {
        store?.deleteSelectedAnnotation()
        onAnnotationsChanged?()
        refreshAnnotations()
        needsDisplay = true
    }
}

// MARK: - Measurement keys

extension CanvasView {

    /// With a marquee, arrows nudge it. Without one, they measure — that is the
    /// ruler, and it is why the two behaviours share a key.
    func handleArrowKey(_ characters: String, step: ImagePx, resize: Bool) -> Bool {
        switch characters {
        case String(UnicodeScalar(NSUpArrowFunctionKey)!):
            if !measureIfNoSelection(.vertical) { nudge(dy: -step, resize: resize) }
        case String(UnicodeScalar(NSDownArrowFunctionKey)!):
            if !measureIfNoSelection(.vertical) { nudge(dy: step, resize: resize) }
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!):
            if !measureIfNoSelection(.horizontal) { nudge(dx: -step, resize: resize) }
        case String(UnicodeScalar(NSRightArrowFunctionKey)!):
            if !measureIfNoSelection(.horizontal) { nudge(dx: step, resize: resize) }
        default:
            return false
        }
        return true
    }

    /// Colour and ruler shortcuts.
    ///
    /// Deliberately bare letters with no modifier: these are used constantly
    /// while the pointer is parked over a pixel, and a chord would mean taking a
    /// hand off the mouse every time.
    func handleMeasurementKey(_ characters: String, event: NSEvent) -> Bool {
        guard let measurement else { return false }

        switch characters {
        case "\t":
            // Tab copies the pixel; Shift-Tab copies the text colour beneath it.
            let copied = event.modifierFlags.contains(.shift)
                ? measurement.pickTextColor()
                : measurement.pickPixelColor()
            if let copied { onStatusMessage?("Copied \(copied)") }
            return true

        case "c":
            if let copied = measurement.pickAverageColor() {
                onStatusMessage?("Copied average \(copied)")
            } else {
                onStatusMessage?("Select an area first")
            }
            return true

        case "p":
            // Display toggle only — the stored measurement never changes.
            measurement.showLogicalPoints.toggle()
            onMeasurementChanged?()
            needsDisplay = true
            return true

        case "x":
            if let summary = measurement.captureForComparison() {
                onStatusMessage?(summary)
            }
            return true

        case "a":
            measurement.autoFitSelection()
            selection = store?.document.selection
            onSelectionChanged?(selection)
            needsDisplay = true
            return true

        default:
            return false
        }
    }

    /// Arrow keys with no selection measure instead of nudging.
    func measureIfNoSelection(_ axis: Axis) -> Bool {
        guard selection == nil, let measurement else { return false }
        measurement.measure(axis: axis)
        onMeasurementChanged?()
        needsDisplay = true
        return true
    }
}
