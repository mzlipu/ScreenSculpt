// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSHotKeys
import SSPersistence
import SwiftUI

/// Hosts the settings window.
///
/// SwiftUI is the right tool here and essentially only here: the panes are
/// forms, toggles and pickers bound to an `@Observable` store, none of it is
/// performance-sensitive, and the alternative is several hundred lines of
/// `NSStackView` wiring. The canvas stays AppKit for exactly the opposite
/// reasons.
@MainActor
public final class SettingsWindowController: NSWindowController {

    private let settings: SettingsStore
    private let hotKeys: HotKeyCenter
    private let permissions: SettingsPermissionBridge

    public init(
        settings: SettingsStore,
        hotKeys: HotKeyCenter,
        permissions: SettingsPermissionBridge
    ) {
        self.settings = settings
        self.hotKeys = hotKeys
        self.permissions = permissions

        let root = SettingsRootView(
            settings: settings, hotKeys: hotKeys, permissions: permissions
        )
        let hosting = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hosting)
        window.title = "ScreenSculpt Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 620, height: 560))
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public func present() {
        // A settings window that opens behind the editor is a bug report
        // waiting to happen.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// What the settings window needs from the permission layer.
///
/// A protocol rather than a direct dependency, because SSSettingsUI has no
/// business importing the capture stack just to show two status rows.
@MainActor
public protocol SettingsPermissionBridge: AnyObject {
    var screenRecordingSummary: String { get }
    var accessibilitySummary: String { get }
    func refresh() async
    func openScreenRecordingSettings()
    func openAccessibilitySettings()
    func relaunch()
    func runDiagnostics() -> String
}
