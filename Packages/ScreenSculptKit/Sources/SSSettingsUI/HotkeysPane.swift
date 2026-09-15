// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSHotKeys
import SwiftUI

struct HotkeysPane: View {
    @Bindable var hotKeys: HotKeyCenter
    @State private var recording: HotKeyID?
    @State private var message: String?

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotKeyID.allCases) { id in
                    HotKeyRow(
                        id: id,
                        binding: hotKeys.bindings[id],
                        isRecording: recording == id,
                        onStart: { recording = id; message = nil },
                        onCancel: { recording = nil },
                        onCapture: { capture($0, for: id) },
                        onClear: {
                            hotKeys.setBinding(nil, for: id)
                            recording = nil
                        }
                    )
                }
            }

            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section {
                Button("Restore defaults") {
                    hotKeys.resetToDefaults()
                    message = nil
                }
                Text("""
                    These work anywhere, in any application. Defaults avoid ⇧⌘3 and ⇧⌘4 \
                    because macOS reserves those for its own screenshot tool and would \
                    win silently.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func capture(_ binding: HotKeyBinding, for id: HotKeyID) {
        recording = nil

        guard binding.isPermissible else {
            message = "\(binding.displayString) needs ⌘, ⌃ or ⌥ — otherwise it would fire "
                + "while you are typing."
            return
        }
        if let clash = hotKeys.conflict(for: binding, excluding: id) {
            message = "\(binding.displayString) is already used by “\(clash.label)”."
            return
        }
        if HotKeyCenter.systemScreenshotShortcuts().contains(binding) {
            message = "\(binding.displayString) belongs to the macOS screenshot tool. "
                + "macOS would win, and nothing would happen."
            return
        }

        switch hotKeys.setBinding(binding, for: id) {
        case .registered:
            message = nil
        case .alreadyTakenBySystem:
            message = "\(binding.displayString) is held by another application."
        case .rejectedInsufficientModifiers:
            message = "\(binding.displayString) needs a modifier key."
        case .failed(let status):
            message = "Could not register \(binding.displayString) (error \(status))."
        }
    }
}

// MARK: - Row

private struct HotKeyRow: View {
    let id: HotKeyID
    let binding: HotKeyBinding?
    let isRecording: Bool
    let onStart: () -> Void
    let onCancel: () -> Void
    let onCapture: (HotKeyBinding) -> Void
    let onClear: () -> Void

    var body: some View {
        LabeledContent(id.label) {
            HStack(spacing: 8) {
                RecorderField(
                    isRecording: isRecording,
                    text: binding?.displayString ?? "Not set",
                    onStart: onStart,
                    onCancel: onCancel,
                    onCapture: onCapture
                )
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(binding == nil ? 0 : 1)
                .disabled(binding == nil)
                .help("Remove this shortcut")
            }
        }
    }
}

/// Click, then press a combination.
///
/// Wraps an AppKit view because SwiftUI has no way to read a raw key code with
/// modifiers before the system interprets it — and the key *code* is what must
/// be stored, since the character depends on the active keyboard layout.
private struct RecorderField: NSViewRepresentable {
    let isRecording: Bool
    let text: String
    let onStart: () -> Void
    let onCancel: () -> Void
    let onCapture: (HotKeyBinding) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onStart = onStart
        view.onCancel = onCancel
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onStart = onStart
        view.onCancel = onCancel
        view.onCapture = onCapture
        view.apply(text: text, recording: isRecording)
    }
}

final class RecorderView: NSView {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCapture: ((HotKeyBinding) -> Void)?

    private var recording = false
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            heightAnchor.constraint(equalToConstant: 24),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    func apply(text: String, recording: Bool) {
        label.stringValue = recording ? "Press a shortcut…" : text
        if self.recording != recording {
            self.recording = recording
            if recording { window?.makeFirstResponder(self) }
        }
        refreshAppearance()
    }

    private func refreshAppearance() {
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor)
            .cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        label.textColor = recording ? .secondaryLabelColor : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        if recording { onCancel?() } else { onStart?(); window?.makeFirstResponder(self) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept before the menu system sees it, or recording ⌘S would
        // trigger Save instead of being captured.
        guard recording else { return false }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        guard recording, handle(event) else { return super.keyDown(with: event) }
    }

    private func handle(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { onCancel?(); return true }  // Escape
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        onCapture?(HotKeyBinding(keyCode: event.keyCode, cocoa: flags))
        return true
    }
}
