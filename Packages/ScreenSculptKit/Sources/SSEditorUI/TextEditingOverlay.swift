// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSAnnotations
import SSDocument
import SSGeometry

/// An inline field for typing into a text annotation.
///
/// A real `NSTextField` placed over the canvas rather than a hand-rolled caret:
/// that gets input methods, dictation, the emoji picker, undo within the field,
/// and right-to-left layout for free — all of which a bespoke editor would have
/// to reimplement badly.
///
/// The field is positioned and sized in view points from the annotation's image
/// rect, so it sits exactly where the finished label will be at any zoom.
@MainActor
final class TextEditingOverlay: NSTextField, NSTextFieldDelegate {

    private var onCommit: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = true
        focusRingType = .none
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        delegate = self
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var isEditing: Bool { !isHidden }

    /// Show the field over `annotation`, matching its colour and size.
    func begin(
        editing annotation: Annotation,
        body: TextBody,
        transform: CanvasTransform,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onCommit = onCommit
        self.onCancel = onCancel

        let box = body.box(style: annotation.style)
        let canvasRect = transform.toCanvas(box).cgRect

        // Font size tracks the zoom so what is typed matches what is drawn.
        let pointSize = max(transform.toCanvas(ImagePx(annotation.style.fontSize)).value, 6)
        font = .systemFont(ofSize: pointSize, weight: .semibold)

        let colour = annotation.style.color
        backgroundColor = NSColor(
            srgbRed: colour.r, green: colour.g, blue: colour.b, alpha: colour.a
        )
        textColor = body.hasBackground ? .white : backgroundColor

        stringValue = body.text
        frame = canvasRect
        isHidden = false
        window?.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: stringValue.count, length: 0)
    }

    func finish() {
        guard isEditing else { return }
        let text = stringValue
        isHidden = true
        stringValue = ""
        let commit = onCommit
        onCommit = nil
        onCancel = nil
        commit?(text)
    }

    private func abandon() {
        guard isEditing else { return }
        isHidden = true
        stringValue = ""
        let cancel = onCancel
        onCommit = nil
        onCancel = nil
        cancel?()
    }

    // MARK: - NSTextFieldDelegate

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finish()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            abandon()
            return true
        default:
            return false
        }
    }

    /// Clicking elsewhere commits rather than discarding — losing typed text
    /// because focus moved is never what anyone wants.
    func controlTextDidEndEditing(_ notification: Notification) {
        finish()
    }
}
