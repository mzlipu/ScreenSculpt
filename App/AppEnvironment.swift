// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSCapture
import SSCaptureUI
import SSDocument
import SSEditorUI
import SSExport
import SSGeometry
import SSImaging
import SSPlatform

/// Composition root — the only place services are constructed and wired.
@MainActor
final class AppEnvironment {

    private let captureService: any CaptureService = ScreenCaptureKitService()
    private let permissions = PermissionBroker()
    private lazy var areaSelection = AreaSelectionController(captureService: captureService)

    private var statusItem: NSStatusItem?
    private var isCapturing = false
    private var confirmationTask: Task<Void, Never>?
    private var lastReceiptURL: URL?

    /// Open editors, retained here because NSWindowController does not retain
    /// itself and the window would otherwise vanish immediately.
    private var editors: [ObjectIdentifier: EditorWindowController] = [:]

    init() {}

    func start() {
        installStatusItem()
        MainMenuBuilder.install(target: self)
        Task { await permissions.refreshScreenRecording() }
        promptToMoveIfTranslocated()
    }

    func stop() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    func showEditor() {
        // Phase 1 week 2. Until the editor exists, the folder is the useful
        // thing to open.
        NSWorkspace.shared.open(Exporter.defaultFolder)
    }

    // MARK: - Capture actions

    @objc func captureFullscreen() {
        runCapture { [captureService] in
            try await captureService.capture(CaptureRequest(mode: .fullscreen(displayID: nil)))
        }
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

    /// Shared pipeline: check permission, capture, then save and copy.
    private func runCapture(_ operation: @escaping () async throws -> CaptureResult?) {
        guard !isCapturing else { return }
        isCapturing = true

        Task { @MainActor in
            defer { isCapturing = false }

            guard await PermissionPresenter.ensureScreenRecording(permissions) else { return }

            do {
                guard let result = try await operation() else { return }  // user cancelled
                openEditor(for: result)
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
        alert.messageText = "Move ScreenSculpt to Applications"
        alert.informativeText = """
            ScreenSculpt is running from a temporary location, so its settings \
            may not persist and it cannot update itself.

            Quit it, drag ScreenSculpt.app into your Applications folder, and \
            open it from there.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Editor

    /// Show the capture in an editor window on the display it came from.
    private func openEditor(for result: CaptureResult) {
        let screen = result.provenance.sourceDisplayID.flatMap { id in
            NSScreen.screens.first { CocoaBridge.displayID(of: $0) == id }
        }
        let controller = EditorWindowController(
            image: result.image,
            measurementUnavailable: result.provenance.spansMixedScales,
            onScreen: screen
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
            guard let receipt = try? Exporter.save(image) else { return }
            self?.announce("Saved", body: receipt.url.lastPathComponent, revealing: receipt.url)
        }
        controller.onClose = { [weak self] in self?.editors[key] = nil }

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
    private func announce(_ title: String, body: String, revealing url: URL? = nil) {
        lastReceiptURL = url
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

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "viewfinder", accessibilityDescription: "ScreenSculpt"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        func add(
            _ title: String, _ action: Selector,
            _ key: String, _ mods: NSEvent.ModifierFlags
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = self
            menu.addItem(item)
        }

        add("Capture Area…", #selector(captureArea), "4", [.command, .shift, .control])
        add("Capture Fullscreen", #selector(captureFullscreen), "3", [.command, .shift, .control])
        add(
            "Capture Active Window", #selector(captureActiveWindow), "5",
            [.command, .shift, .control]
        )

        menu.addItem(.separator())

        let folder = NSMenuItem(
            title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: ""
        )
        folder.target = self
        menu.addItem(folder)

        let permissionsItem = NSMenuItem(
            title: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let version = NSMenuItem(
            title: "ScreenSculpt \(Self.versionString)", action: nil, keyEquivalent: ""
        )
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(NSMenuItem(
            title: "Quit ScreenSculpt",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return menu
    }

    @objc private func openFolder() {
        let folder = Exporter.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let last = lastReceiptURL, FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc private func checkPermissions() {
        Task { @MainActor in
            let screen = await permissions.refreshScreenRecording()
            let axState = permissions.refreshAccessibility()

            let alert = NSAlert()
            alert.messageText = "Permissions"
            alert.informativeText = """
                Screen Recording: \(Self.describe(screen))
                \(permissions.advice(for: .screenRecording))

                Accessibility: \(Self.describe(axState))
                Only needed for automatic scrolling capture, which is not built yet.

                Screenshots folder:
                \(Exporter.defaultFolder.path)
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Relaunch ScreenSculpt")
            alert.addButton(withTitle: "Done")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn: permissions.openSettings(for: .screenRecording)
            case .alertSecondButtonReturn: permissions.relaunch()
            default: break
            }
        }
    }

    private static func describe(_ state: PermissionState) -> String {
        switch state {
        case .granted: "granted"
        case .denied: "denied"
        case .notDetermined: "not yet requested"
        case .needsRelaunch: "granted — reopen ScreenSculpt to apply it"
        case .staleGrant: "approved, but recorded against an older build"
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
