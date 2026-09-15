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

    @Test("Defaults avoid the system screenshot shortcuts")
    func defaultsAvoidSystemShortcuts() {
        // macOS owns Shift-Command-3/4/5 and wins silently, so every default
        // must carry Control as well.
        for id in HotKeyID.allCases {
            guard let binding = id.defaultBinding else { continue }
            #expect(binding.cocoaModifiers.contains(.control), "\(id.label) would collide")
            #expect(binding.isPermissible)
        }
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
