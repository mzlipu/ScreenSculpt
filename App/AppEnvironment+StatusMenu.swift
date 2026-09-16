// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSExport
import SSHotKeys
import SSPersistence
import SSPlatform

/// The menu bar item and its menu.
///
/// Split from the composition root because the menu is the app's entire visible
/// surface when no editor is open, and it grows with every new capture mode.
extension AppEnvironment {

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A template image: macOS inverts it for light and dark menu bars, and
        // for the highlighted state. A coloured icon would be wrong in at least
        // one of the three.
        let icon = NSImage(named: "MenuBarIcon") ?? NSImage(
            systemSymbolName: "viewfinder", accessibilityDescription: "Screen Sculpt"
        )
        icon?.isTemplate = true
        icon?.size = NSSize(width: 18, height: 18)
        item.button?.image = icon
        item.button?.toolTip = "Screen Sculpt"

        item.menu = buildMenu()
        statusItem = item
    }

    func buildMenu() -> NSMenu {
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

        // Read from the live bindings rather than repeating them as literals.
        // Hardcoding meant the menu kept advertising a shortcut the user had
        // already changed — and quietly went stale when the defaults moved.
        func addCapture(_ title: String, _ action: Selector, _ id: HotKeyID) {
            guard let equivalent = hotKeys.bindings[id]?.menuKeyEquivalent else {
                add(title, action, "", [])
                return
            }
            add(title, action, equivalent.key, equivalent.modifiers)
        }

        addCapture("Capture Area…", #selector(captureArea), .captureArea)
        addCapture("Capture Fullscreen", #selector(captureFullscreen), .captureFullscreen)
        addCapture("Capture Active Window", #selector(captureActiveWindow), .captureWindow)
        addCapture("Capture Scrolling Page…", #selector(captureScrolling), .captureScrolling)
        addCapture("Recognise Text…", #selector(recogniseTextFromScreen), .recogniseText)

        menu.addItem(.separator())

        let folder = NSMenuItem(
            title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: ""
        )
        folder.target = self
        menu.addItem(folder)

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(showSettings), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(
            title: "Check Permissions…", action: #selector(checkPermissions), keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())

        let version = NSMenuItem(
            title: "Screen Sculpt \(Self.versionString)", action: nil, keyEquivalent: ""
        )
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(NSMenuItem(
            title: "Quit Screen Sculpt",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        return menu
    }

    @objc func openFolder() {
        let folder = Exporter.defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let last = lastReceiptURL, FileManager.default.fileExists(atPath: last.path) {
            NSWorkspace.shared.activateFileViewerSelecting([last])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    @objc func checkPermissions() {
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
            alert.addButton(withTitle: "Relaunch Screen Sculpt")
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
        case .needsRelaunch: "granted — reopen Screen Sculpt to apply it"
        case .staleGrant: "approved, but recorded against an older build"
        }
    }

}
