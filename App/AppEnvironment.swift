// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSGeometry
import SSPlatform

/// Composition root.
///
/// The one place services are constructed and wired. Everything else receives
/// its collaborators, which is what keeps the modules independently testable
/// and stops a singleton graph forming.
@MainActor
final class AppEnvironment {

    private var statusItem: NSStatusItem?

    init() {}

    func start() {
        installStatusItem()
        MainMenuBuilder.install()
    }

    func stop() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    func showEditor() {
        // Phase 1 week 2. The editor window controller lands with SSEditorUI.
        NSSound.beep()
    }

    // MARK: - Status item
    //
    // Placeholder menu. In Phase 1 this is rebuilt from `[AppCommand]` so that
    // the status menu, the main menu, global hotkeys and the URL scheme all
    // funnel through one dispatcher and cannot drift apart.

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "viewfinder", accessibilityDescription: "ScreenSculpt"
        )
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(
            withTitle: "ScreenSculpt \(Self.versionString)", action: nil, keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit ScreenSculpt",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu
        statusItem = item
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
