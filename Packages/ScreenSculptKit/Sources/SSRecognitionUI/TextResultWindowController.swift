// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSRecognition

/// Shows what recognition actually read.
///
/// The text is on the clipboard before this appears — the fast path, hotkey to
/// paste, is why OCR is on a shortcut at all and it should not require
/// dismissing a window. What the window adds is the ability to *check*: OCR
/// fails quietly, and a silent copy gives no way to tell a clean read from a
/// mangled one until the wrong text is already pasted somewhere.
///
/// Editable on purpose. A misread character is faster to fix here than to
/// notice later, and the Copy button always takes what is on screen rather
/// than what was originally recognised.
@MainActor
public final class TextResultWindowController: NSWindowController {

    private let blocks: [TextBlock]
    private let confidence: Float
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let joinToggle = NSButton(
        checkboxWithTitle: "Join wrapped lines", target: nil, action: nil
    )
    private var removeLineBreaks: Bool

    /// Called when the text is copied, so the app can show its usual confirmation.
    public var onCopy: ((String) -> Void)?

    public init(result: RecognizedText, removeLineBreaks: Bool) {
        self.blocks = result.blocks
        self.confidence = result.meanConfidence
        self.removeLineBreaks = removeLineBreaks

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Recognised Text"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        build(into: window, text: result.plainText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Layout

    private func build(into window: NSWindow, text: String) {
        let content = NSView()
        window.contentView = content

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        textView.string = text
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        // Recognised text is data, not prose being written. Autocorrecting it
        // would quietly change what the image actually said.
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        scroll.documentView = textView

        joinToggle.state = removeLineBreaks ? .on : .off
        joinToggle.target = self
        joinToggle.action = #selector(toggleJoin)
        joinToggle.toolTip =
            "Rejoin lines that were wrapped by the layout, keeping deliberate breaks."

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let copy = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copy.keyEquivalent = "\r"
        copy.bezelStyle = .rounded

        let footer = NSStackView(views: [joinToggle, NSView(), statusLabel, copy])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 10, right: 14)

        let stack = NSStackView(views: [scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        footer.setHuggingPriority(.defaultHigh, for: .vertical)

        updateStatus()
    }

    // MARK: - Actions

    @objc private func toggleJoin() {
        removeLineBreaks = joinToggle.state == .on
        // Re-joined from the blocks, not by editing the string: whether a break
        // was the layout wrapping or the author's own is a question about where
        // the words sat on screen, and only the blocks still know that.
        textView.string = ReadingOrder.join(blocks, removingLineBreaks: removeLineBreaks)
        updateStatus()
    }

    @objc private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        onCopy?(textView.string)
        updateStatus(copied: true)
    }

    private func updateStatus(copied: Bool = false) {
        let text = textView.string
        let lines = text.isEmpty
            ? 0
            : text.split(separator: "\n", omittingEmptySubsequences: false).count
        var parts = ["\(lines) line\(lines == 1 ? "" : "s")", "\(text.count) characters"]

        // Say so when the read was poor. Recognition returns something for
        // almost any image, and a confident-looking window full of nonsense is
        // worse than no window.
        if confidence > 0, confidence < 0.5 {
            parts.append("low confidence — check it against the image")
        }
        if copied { parts.insert("Copied", at: 0) }
        statusLabel.stringValue = parts.joined(separator: " · ")
    }

    public func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        textView.window?.makeFirstResponder(textView)
    }
}

extension TextResultWindowController: NSTextViewDelegate {
    public func textDidChange(_ notification: Notification) {
        updateStatus()
    }
}
