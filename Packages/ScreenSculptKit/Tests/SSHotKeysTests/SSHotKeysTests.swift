// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import Foundation
import Testing

@testable import SSHotKeys

@Suite("Hotkey bindings")
@MainActor
struct HotKeyBindingTests {

    @Test("Cocoa and Carbon modifier masks round-trip")
    func modifierRoundTrip() {
        let combinations: [NSEvent.ModifierFlags] = [
            [.command],
            [.command, .shift],
            [.control, .shift, .command],
            [.option, .command],
            [.control, .option, .shift, .command],
        ]
        for flags in combinations {
            let binding = HotKeyBinding(keyCode: 21, cocoa: flags)
            #expect(binding.cocoaModifiers == flags)
        }
    }

    @Test("A binding without Command, Control or Option is rejected")
    func requiresRealModifier() {
        // A bare key, or Shift plus a key, would fire while the user is typing
        // in any other application.
        #expect(!HotKeyBinding(keyCode: 21, cocoa: []).isPermissible)
        #expect(!HotKeyBinding(keyCode: 21, cocoa: [.shift]).isPermissible)

        #expect(HotKeyBinding(keyCode: 21, cocoa: [.command]).isPermissible)
        #expect(HotKeyBinding(keyCode: 21, cocoa: [.control]).isPermissible)
        #expect(HotKeyBinding(keyCode: 21, cocoa: [.option]).isPermissible)
    }

    @Test("Modifiers are displayed in the conventional macOS order")
    func displayOrder() {
        let binding = HotKeyBinding(
            keyCode: 21, cocoa: [.command, .shift, .control, .option]
        )
        let text = binding.displayString
        // macOS renders ⌃⌥⇧⌘, always in that order.
        let control = text.firstIndex(of: "⌃")!
        let option = text.firstIndex(of: "⌥")!
        let shift = text.firstIndex(of: "⇧")!
        let command = text.firstIndex(of: "⌘")!
        #expect(control < option)
        #expect(option < shift)
        #expect(shift < command)
    }

    @Test("Special keys get a symbol rather than a question mark")
    func specialKeyNames() {
        #expect(HotKeyBinding(keyCode: 49, cocoa: [.command]).displayString.hasSuffix("Space"))
        #expect(HotKeyBinding(keyCode: 36, cocoa: [.command]).displayString.hasSuffix("↩"))
        #expect(HotKeyBinding(keyCode: 122, cocoa: [.command]).displayString.hasSuffix("F1"))
    }

    @Test("Bindings encode and decode")
    func codable() throws {
        let binding = HotKeyBinding(keyCode: 21, cocoa: [.control, .shift, .command])
        let data = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(HotKeyBinding.self, from: data) == binding)
    }

    /// The combinations macOS ships enabled out of the box, from
    /// `com.apple.symbolichotkeys` ids 28, 29, 30, 31 and 184.
    ///
    /// Hardcoded rather than read from the running system: the test has to hold
    /// for every user's Mac, not just one where somebody happened to disable a
    /// shortcut.
    static let factoryScreenshotShortcuts: [HotKeyBinding] = [
        HotKeyBinding(keyCode: 20, cocoa: [.shift, .command]),              // ⇧⌘3
        HotKeyBinding(keyCode: 20, cocoa: [.control, .shift, .command]),    // ⌃⇧⌘3
        HotKeyBinding(keyCode: 21, cocoa: [.shift, .command]),              // ⇧⌘4
        HotKeyBinding(keyCode: 21, cocoa: [.control, .shift, .command]),    // ⌃⇧⌘4
        HotKeyBinding(keyCode: 23, cocoa: [.shift, .command]),              // ⇧⌘5
    ]

    /// Registering a combination macOS owns *appears* to succeed and then never
    /// fires, so a collision here is invisible at runtime — the test is the only
    /// place it shows up.
    @Test("Defaults avoid the system screenshot shortcuts")
    func defaultsAvoidSystemShortcuts() {
        for id in HotKeyID.allCases {
            guard let binding = id.defaultBinding else { continue }
            #expect(
                !Self.factoryScreenshotShortcuts.contains(binding),
                "\(id.label) is bound to \(binding.displayString), which macOS owns"
            )
            #expect(binding.isPermissible)
        }
    }

    @Test("Defaults are the combinations the product documents")
    func defaultsAreAsDocumented() {
        #expect(HotKeyID.captureFullscreen.defaultBinding?.displayString == "⇧⌘1")
        #expect(HotKeyID.captureArea.defaultBinding?.displayString == "⇧⌘2")
        #expect(HotKeyID.recogniseText.defaultBinding?.displayString == "⇧⌘O")
    }

    /// The migration's whole purpose: adopt a new default only where the user
    /// never expressed a preference.
    @Test("A superseded default is distinguishable from a chosen binding")
    func legacyDefaultsAreRecorded() {
        for id in HotKeyID.allCases {
            guard let legacy = HotKeyID.legacyDefaultBinding(for: id) else { continue }
            #expect(legacy != id.defaultBinding || id == .captureWindow || id == .captureRepeat)
        }
        // Unchanged between revisions, so migration must leave them alone.
        #expect(HotKeyID.legacyDefaultBinding(for: .captureWindow)
            == HotKeyID.captureWindow.defaultBinding)
    }

    @Test("Every command has a distinct Carbon id")
    func uniqueCarbonIDs() {
        let ids = HotKeyID.allCases.map(\.carbonID)
        #expect(Set(ids).count == ids.count)
        // Zero is used as "none" by the shim.
        #expect(!ids.contains(0))
    }

    @Test("Default bindings do not collide with each other")
    func defaultsAreDistinct() {
        let bindings = HotKeyID.allCases.compactMap(\.defaultBinding)
        #expect(Set(bindings).count == bindings.count)
    }
}
