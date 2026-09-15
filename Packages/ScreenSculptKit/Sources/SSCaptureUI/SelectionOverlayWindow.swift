// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSGeometry
import SSImaging

/// A borderless, full-display shield showing that display's frozen frame.
@MainActor
final class SelectionOverlayWindow: NSWindow {

    /// Emits the selected rect in the display's own coordinates: top-left
    /// origin, Y down, logical points.
    var onCommit: ((ImageRect) -> Void)?
    var onCancel: (() -> Void)?
    var onCursorMoved: (() -> Void)?

    private var overlayView: SelectionOverlayView!

    /// NSWindow's *designated* initialiser.
    ///
    /// This override is not decoration. `NSWindow.init(contentRect:styleMask:
    /// backing:defer:screen:)` is a convenience initialiser that calls straight
    /// back into this one on the subclass. Declaring our own designated
    /// initialiser without overriding this left Swift's trapping stub in place
    /// for it, so AppKit's call landed on `fatalError` and the app died with
    /// EXC_BREAKPOINT the moment an overlay was created.
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect, styleMask: style,
            backing: backingStoreType, defer: flag
        )
    }

    /// Build a shield sized to one display and showing its frozen frame.
    convenience init(screen: NSScreen, snapshot: DisplaySnapshot, frozenImage: RasterImage) {
        self.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        let view = SelectionOverlayView(
            frozenImage: frozenImage,
            pointSize: screen.frame.size
        )
        overlayView = view

        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        // Above everything, including other applications' full-screen windows.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        contentView = view

        // The convenience initialiser cannot pass `screen:`, so place the
        // window explicitly. setFrame also keeps this correct if the display
        // arrangement changed between the capture and now.
        setFrame(screen.frame, display: false)

        view.onCommit = { [weak self] rect in self?.onCommit?(rect) }
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.onCursorMoved = { [weak self] in self?.onCursorMoved?() }
    }

    /// Borderless windows refuse key status by default, and without it the view
    /// never receives Escape or arrow keys.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func clearSelection() { overlayView.clearSelection() }

    override func mouseDown(with event: NSEvent) { overlayView.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { overlayView.keyDown(with: event) }
}

// MARK: - View

@MainActor
final class SelectionOverlayView: NSView {

    var onCommit: ((ImageRect) -> Void)?
    var onCancel: (() -> Void)?
    var onCursorMoved: (() -> Void)?

    private let frozen: CGImage
    private let scale: PixelScale
    private let pointSize: NSSize

    private var anchor: NSPoint?
    private var current: NSPoint?
    private var cursor: NSPoint = .zero
    private var isDragging = false

    private static let loupeSide: CGFloat = 132
    private static let loupeZoom: CGFloat = 8

    init(frozenImage: RasterImage, pointSize: NSSize) {
        frozen = frozenImage.cgImage
        scale = frozenImage.pixelScale
        self.pointSize = pointSize
        super.init(frame: NSRect(origin: .zero, size: pointSize))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func clearSelection() {
        anchor = nil
        current = nil
        isDragging = false
        needsDisplay = true
    }

    // MARK: Selection geometry, in flipped view points

    private var selectionRect: NSRect? {
        guard let anchor, let current else { return nil }
        let rect = NSRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
        return rect.width >= 1 && rect.height >= 1 ? rect : nil
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        if event.type == .rightMouseDown { onCancel?(); return }
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        var point = convert(event.locationInWindow, from: nil)

        // Shift constrains to a square, measured from the anchor.
        if event.modifierFlags.contains(.shift), let anchor {
            let side = max(abs(point.x - anchor.x), abs(point.y - anchor.y))
            point = NSPoint(
                x: anchor.x + (point.x < anchor.x ? -side : side),
                y: anchor.y + (point.y < anchor.y ? -side : side)
            )
        }
        current = point
        cursor = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        guard let rect = selectionRect else { onCancel?(); return }
        onCommit?(ImageRect(
            x: ImagePx(rect.minX), y: ImagePx(rect.minY),
            width: ImagePx(rect.width), height: ImagePx(rect.height)
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        onCursorMoved?()
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape. Comparing key codes avoids depending on the layout.
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // The frozen frame, filling the display.
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(frozen, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()

        let selection = selectionRect

        // Dim everything outside the selection.
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        if let selection {
            context.addRect(bounds)
            context.addRect(selection)
            context.fillPath(using: .evenOdd)
        } else {
            context.fill(bounds)
        }

        if let selection {
            drawMarquee(selection, in: context)
            drawSizeReadout(for: selection, in: context)
        } else {
            drawCrosshair(in: context)
        }

        drawLoupe(in: context)
    }

    private func drawMarquee(_ rect: NSRect, in context: CGContext) {
        context.setStrokeColor(NSColor.white.cgColor)
        // One physical pixel, so the marquee edge is exact rather than a
        // two-pixel smear straddling a pixel boundary.
        context.setLineWidth(1.0 / scale.value)
        context.stroke(rect)

        context.setFillColor(NSColor.white.cgColor)
        let knob: CGFloat = 5
        for point in [
            NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.minY),
            NSPoint(x: rect.minX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.maxY),
        ] {
            context.fillEllipse(in: CGRect(
                x: point.x - knob / 2, y: point.y - knob / 2, width: knob, height: knob
            ))
        }
    }

    private func drawCrosshair(in context: CGContext) {
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(1.0 / scale.value)
        context.beginPath()
        context.move(to: CGPoint(x: cursor.x, y: 0))
        context.addLine(to: CGPoint(x: cursor.x, y: bounds.height))
        context.move(to: CGPoint(x: 0, y: cursor.y))
        context.addLine(to: CGPoint(x: bounds.width, y: cursor.y))
        context.strokePath()
    }

    /// Both units, always — the point size is what a designer specifies, the
    /// pixel size is what the file will be.
    private func drawSizeReadout(for rect: NSRect, in context: CGContext) {
        let points = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded())) pt"
        let pixels = "\(Int((rect.width * scale.value).rounded())) × "
            + "\(Int((rect.height * scale.value).rounded())) px"
        let text = scale.isRetina ? "\(points)   \(pixels)" : points

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding: CGFloat = 6

        var origin = NSPoint(x: rect.minX, y: rect.maxY + padding)
        if origin.y + size.height + padding * 2 > bounds.height {
            origin.y = rect.minY - size.height - padding * 3
        }
        origin.x = min(max(origin.x, 4), bounds.width - size.width - padding * 2 - 4)

        let box = NSRect(
            x: origin.x, y: origin.y,
            width: size.width + padding * 2, height: size.height + padding
        )
        context.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        context.fill(box)
        string.draw(at: NSPoint(x: box.minX + padding, y: box.minY + padding / 2))
    }

    /// Magnifier sampled from the already-captured frozen frame — exact, free,
    /// and immune to drawing the overlay into itself.
    private func drawLoupe(in context: CGContext) {
        let side = Self.loupeSide
        let sourceSide = side / Self.loupeZoom

        let sourcePixels = CGRect(
            x: (cursor.x - sourceSide / 2) * scale.value,
            y: (cursor.y - sourceSide / 2) * scale.value,
            width: sourceSide * scale.value,
            height: sourceSide * scale.value
        )
        guard let patch = frozen.cropping(to: sourcePixels) else { return }

        var origin = NSPoint(x: cursor.x + 20, y: cursor.y + 20)
        if origin.x + side > bounds.width { origin.x = cursor.x - side - 20 }
        if origin.y + side > bounds.height { origin.y = cursor.y - side - 20 }
        let frame = NSRect(x: origin.x, y: origin.y, width: side, height: side)

        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let flipped = NSRect(
            x: frame.minX, y: bounds.height - frame.maxY, width: side, height: side
        )
        // Nearest-neighbour: a smoothed magnifier in a pixel tool is a lie
        // about what is actually on screen.
        context.interpolationQuality = .none
        context.draw(patch, in: flipped)
        context.restoreGState()

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(frame)

        // Outline the exact pixel under the cursor.
        let pixel = side / (sourceSide * scale.value)
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(
            x: frame.midX - pixel / 2, y: frame.midY - pixel / 2,
            width: pixel, height: pixel
        ))
    }
}
