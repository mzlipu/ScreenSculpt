// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSCapture
import SSCaptureUI
import SSDocument
import SSEditorUI
import SSExport
import SSGeometry
import SSHotKeys
import SSImaging
import SSPersistence
import SSPlatform
import SSRecognition
import SSRecognitionUI
import SSSettingsUI

/// Composition root — the only place services are constructed and wired.
@MainActor
final class AppEnvironment {

    let captureService: any CaptureService = ScreenCaptureKitService()
    let permissions = PermissionBroker()
    let settings = SettingsStore()
    lazy var areaSelection = AreaSelectionController(captureService: captureService)
    /// Not private: the status menu reads it so the shortcuts it shows are the
    /// ones actually registered.
    lazy var hotKeys = HotKeyCenter(settings: settings)
    private lazy var permissionBridge = PermissionBridge(broker: permissions)
    var settingsWindow: SettingsWindowController?
    var textResultWindow: TextResultWindowController?

    var statusItem: NSStatusItem?
    var isCapturing = false
    var confirmationTask: Task<Void, Never>?
    var lastReceiptURL: URL?

    /// Open editors, retained here because NSWindowController does not retain
    /// itself and the window would otherwise vanish immediately.
    var editors: [ObjectIdentifier: EditorWindowController] = [:]

    init() {}

    func start() {
        installStatusItem()
        MainMenuBuilder.install(target: self)
        installHotKeys()
        applyAppearanceSettings()
        Task { await permissions.refreshScreenRecording() }
        promptToMoveIfTranslocated()
    }

    /// Global shortcuts, live from launch.
    private func installHotKeys() {
        hotKeys.onTrigger = { [weak self] id in
            guard let self else { return }
            switch id {
            case .captureArea: captureArea()
            case .captureFullscreen: captureFullscreen()
            case .captureWindow: captureActiveWindow()
            case .captureScrolling: captureScrolling()
            case .captureRepeat: captureArea()      // repeat-region lands with Phase 2
            case .captureDelayed: captureFullscreen()
            case .recogniseText: recogniseTextFromScreen()
            case .showApp: showEditor()
            }
        }
        hotKeys.registerAll()
    }

    private func applyAppearanceSettings() {
        updateDockPresence()
        statusItem?.isVisible = !settings[Settings.hideMenuBarIcon]
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings, hotKeys: hotKeys, permissions: permissionBridge
            )
            settingsWindow?.onClose = { [weak self] in
                // Deferred: the window is still closing, and dropping to
                // accessory mid-teardown makes it visibly stutter.
                DispatchQueue.main.async { self?.updateDockPresence() }
            }
        }
        updateDockPresence()
        settingsWindow?.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    func stop() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc func captureFullscreen() {
        let cursor = cursorPolicy
        runCapture { [captureService] in
            try await captureService.capture(
                CaptureRequest(mode: .fullscreen(displayID: nil), cursor: cursor)
            )
        }
    }

    private var cursorPolicy: CursorPolicy {
        settings[Settings.cursor] == .include ? .include : .exclude
    }

    @objc func captureArea() {
        runCapture { [areaSelection] in
            guard let selection = try await areaSelection.selectRegion() else { return nil }
            return CaptureResult(
                image: selection.image,
                provenance: CaptureProvenance(
                    sourceRect: selection.rect,
                    pixelScale: selection.pixelScale,
                    displays: [],
                    sourceDisplayID: selection.displayID,
                    spansMixedScales: false
                )
            )
        }
    }

    @objc func captureActiveWindow() {
        runCapture { [captureService] in
            try await captureService.capture(CaptureRequest(mode: .activeWindow))
        }
    }

    /// Route the result according to the "after a capture" preference.
    private func deliver(_ result: CaptureResult) {
        let action = settings[Settings.afterCapture]

        if action.opensEditor {
            openEditor(for: result)
            return
        }

        var parts: [String] = []
        if action.copies, (try? ClipboardWriter.copy(result.image)) != nil {
            parts.append("copied")
        }
        if action.saves, let receipt = saveImage(result.image) {
            parts.append(receipt.url.lastPathComponent)
            announce("Saved", body: parts.joined(separator: " · "), revealing: receipt.url)
            return
        }
        announce("Captured", body: parts.isEmpty ? "Done" : parts.joined(separator: " · "))
    }

    /// Saving honours the folder, format and downscale preferences.
    @discardableResult
    func saveImage(_ image: RasterImage) -> ExportReceipt? {
        let format: SaveFormat = switch settings[Settings.saveFormat] {
        case .auto: .auto
        case .png: .png
        case .jpeg: .jpeg
        }
        return try? Exporter.save(
            image,
            to: settings.screenshotFolder,
            format: format,
            downscaleToOneX: settings[Settings.downscaleRetina],
            template: settings[Settings.filenameTemplate]
        )
    }

    /// Shared pipeline: check permission, capture, then save and copy.
    private func runCapture(_ operation: @escaping () async throws -> CaptureResult?) {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }

            guard await PermissionPresenter.ensureScreenRecording(permissions) else { return }

            do {
                guard let result = try await operation() else { return }  // user cancelled
                deliver(result)
            } catch let error as CaptureError {
                presentCaptureError(error)
            } catch {
                announce("Screenshot failed", body: error.localizedDescription)
            }
        }
    }

    private func presentCaptureError(_ error: CaptureError) {
        switch error {
        case .permissionDenied, .permissionStale:
            PermissionPresenter.present(
                permissions,
                title: "Screen recording permission is needed",
                body: permissions.advice(for: .screenRecording),
                offerRelaunch: true
            )
        default:
            announce("Screenshot failed", body: error.localizedDescription)
        }
    }

    /// Running from a DMG or ~/Downloads puts the app in a randomised read-only
    /// mount, where preferences may not persist and updates cannot install.
    private func promptToMoveIfTranslocated() {
        guard permissions.isTranslocated else { return }
        let alert = NSAlert()
        alert.messageText = "Move Screen Sculpt to Applications"
        alert.informativeText = """
            ScreenSculpt is running from a temporary location, so its settings \
            may not persist and it cannot update itself.

            Quit it, drag ScreenSculpt.app into your Applications folder, and \
            open it from there.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Select a region and copy its text straight to the clipboard.
    ///
    /// Deliberately never opens the editor: the point of this mode is to get
    /// text out of something unselectable in one gesture.
    @objc func recogniseTextFromScreen() {
        // A global hotkey is registered exclusively, so it fires even while an
        // editor is frontmost — shadowing that window's own Recognise Text item.
        // Route it back there, or the same keystroke would mean two different
        // things depending on which one macOS happened to deliver it to.
        if let editor = NSApp.keyWindow?.windowController as? EditorWindowController {
            editor.recogniseText()
            return
        }
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }
            guard await PermissionPresenter.ensureScreenRecording(permissions) else { return }

            do {
                guard let selection = try await areaSelection.selectRegion() else { return }
                let recognizer = TextRecognizer(
                    languages: [settings[Settings.primaryOCRLanguage]],
                    removeLineBreaks: settings[Settings.ocrRemoveLineBreaks]
                )
                let result = try recognizer.recognize(in: selection.image)
                // Copied first, always. The window is for checking the result,
                // not for obtaining it — hotkey to paste has to keep working
                // without a window in the way.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.plainText, forType: .string)

                let lines = result.plainText.split(separator: "\n").count
                announce("Text copied", body: lines == 1 ? "1 line" : "\(lines) lines")

                if settings[Settings.showRecognisedText] { showRecognisedText(result) }
            } catch {
                announce("No text found", body: error.localizedDescription)
            }
        }
    }

    // MARK: - Editor

    /// Show the capture in an editor window on the display it came from.
    func openEditor(for result: CaptureResult) {
        let screen = result.provenance.sourceDisplayID.flatMap { id in
            NSScreen.screens.first { CocoaBridge.displayID(of: $0) == id }
        }
        let controller = EditorWindowController(
            image: result.image,
            measurementUnavailable: result.provenance.spansMixedScales,
            onScreen: screen,
            settings: settings
        )
        // NSWindowController does not retain itself, so the window would close
        // the moment this function returns.
        let key = ObjectIdentifier(controller)
        editors[key] = controller

        controller.onCopy = { [weak self] image in
            _ = try? ClipboardWriter.copy(image)
            self?.announce("Copied", body: "Image copied to the clipboard")
        }
        controller.onSave = { [weak self] image in
            guard let receipt = self?.saveImage(image) else { return }
            self?.announce("Saved", body: receipt.url.lastPathComponent, revealing: receipt.url)
        }
        controller.onStatusMessage = { [weak self] message in
            self?.announce(message, body: message)
        }
        wireAppendRequest(on: controller)
        controller.onClose = { [weak self] in
            self?.editors[key] = nil
            // Deferred by one turn: the window is still tearing down, and
            // dropping to accessory mid-teardown makes the close visibly stutter.
            DispatchQueue.main.async { self?.updateDockPresence() }
        }

        // Before showing the window, so it opens into an app that already has a
        // Dock presence rather than acquiring one underneath itself.
        updateDockPresence()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Feedback

    /// Brief confirmation in the menu bar itself.
    ///
    /// Deliberately not a system notification: those need authorisation the
    /// user may never grant, and an unsigned build often cannot obtain it — so
    /// a capture would appear to do nothing. The menu bar is always visible and
    /// always ours.
    func announce(_ title: String, body: String, revealing url: URL? = nil) {
        lastReceiptURL = url
        guard settings[Settings.confirmation] == .menuBar else { return }
        guard let button = statusItem?.button else { return }

        button.contentTintColor = .controlAccentColor
        button.title = url.map { " \($0.lastPathComponent)" } ?? " \(title)"
        button.toolTip = body

        confirmationTask?.cancel()
        confirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            button.contentTintColor = nil
            button.title = ""
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
