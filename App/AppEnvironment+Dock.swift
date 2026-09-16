// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSPersistence

/// Whether the app appears in the Dock.
///
/// A capture utility spends most of its life with nothing on screen. A Dock
/// tile for an app with no window is an icon that does nothing when clicked —
/// which is what this app shipped with, pointed at the screenshots folder for
/// want of anything better. But an app that *does* have a window and no Dock
/// tile cannot be reached with Command-Tab, so neither fixed answer is right.
/// The presence follows the windows instead.
extension AppEnvironment {

    /// Show the app in the Dock only while it has a window worth switching to.
    ///
    /// Activation policy, not a window property. `.accessory` keeps the menu
    /// bar item and drops the Dock tile; `.regular` restores both. Called
    /// whenever a window opens or closes, so the Dock follows what is actually
    /// on screen.
    func updateDockPresence() {
        let wanted: NSApplication.ActivationPolicy = switch settings[Settings.dockIconMode] {
        case .always: .regular
        case .never: .accessory
        case .automatic: hasVisibleWindow ? .regular : .accessory
        }
        guard NSApp.activationPolicy() != wanted else { return }

        NSApp.setActivationPolicy(wanted)
        // Going from accessory to regular hands focus back to whatever was in
        // front, leaving the new window behind it. Reactivating has to happen
        // after the policy change, not before.
        if wanted == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    private var hasVisibleWindow: Bool {
        if !editors.isEmpty { return true }
        if textResultWindow?.window?.isVisible == true { return true }
        return settingsWindow?.window?.isVisible ?? false
    }

    /// Bring the frontmost editor forward, if there is one.
    ///
    /// Reached by clicking the Dock icon. It used to open the screenshots
    /// folder — a stand-in from before the editor existed, which by now just
    /// made the Dock tile do something unrelated to the app.
    func showEditor() {
        guard let controller = editors.values.first else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Capture actions
}
