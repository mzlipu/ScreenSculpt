// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CHotKeyShim
import Carbon.HIToolbox
import Foundation

/// Which command a hotkey triggers.
public enum HotKeyID: String, Sendable, CaseIterable, Identifiable, Codable {
    case captureArea
    case captureFullscreen
    case captureWindow
    case captureScrolling
    case captureRepeat
    case captureDelayed
    case recogniseText
    case showApp

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .captureArea: "Capture area"
        case .captureFullscreen: "Capture fullscreen"
        case .captureWindow: "Capture active window"
        case .captureScrolling: "Capture scrolling page"
        case .captureRepeat: "Repeat last area"
        case .captureDelayed: "Delayed capture"
        case .recogniseText: "Recognise text (OCR)"
        case .showApp: "Show ScreenSculpt"
        }
    }

    /// Stable numeric id for the Carbon registry.
    var carbonID: UInt32 {
        UInt32(HotKeyID.allCases.firstIndex(of: self)! + 1)
    }
}

/// A key plus modifiers.
///
/// Stores the **virtual key code**, never the character. The character depends
/// on the active keyboard layout, so a binding saved on a French layout would
/// otherwise move when the user switches to English.
public struct HotKeyBinding: Sendable, Codable, Equatable, Hashable {
    public var keyCode: UInt16
    public var modifiers: UInt32  // Carbon modifier mask

    public init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init(keyCode: UInt16, cocoa: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = Self.carbonModifiers(from: cocoa)
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(kSSCmdKeyMask) }
        if flags.contains(.shift) { mask |= UInt32(kSSShiftKeyMask) }
        if flags.contains(.option) { mask |= UInt32(kSSOptionKeyMask) }
        if flags.contains(.control) { mask |= UInt32(kSSControlKeyMask) }
        return mask
    }

    public var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(kSSCmdKeyMask) != 0 { flags.insert(.command) }
        if modifiers & UInt32(kSSShiftKeyMask) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(kSSOptionKeyMask) != 0 { flags.insert(.option) }
        if modifiers & UInt32(kSSControlKeyMask) != 0 { flags.insert(.control) }
        return flags
    }

    /// At least one of Command, Control or Option.
    ///
    /// A bare key, or Shift plus a key, would fire while the user is typing in
    /// any other application.
    public var isPermissible: Bool {
        modifiers & UInt32(kSSCmdKeyMask | kSSControlKeyMask | kSSOptionKeyMask) != 0
    }

    /// `⌃⇧⌘4` — built from the *current* layout, so it stays truthful when the
    /// user switches keyboards.
    public var displayString: String {
        var text = ""
        if modifiers & UInt32(kSSControlKeyMask) != 0 { text += "⌃" }
        if modifiers & UInt32(kSSOptionKeyMask) != 0 { text += "⌥" }
        if modifiers & UInt32(kSSShiftKeyMask) != 0 { text += "⇧" }
        if modifiers & UInt32(kSSCmdKeyMask) != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// The binding expressed as an `NSMenuItem` key equivalent.
    ///
    /// Menu equivalents are characters, so a key with no character — Space,
    /// Return, the function row — cannot be shown and returns an empty string.
    /// Showing nothing is right: a menu that displays the wrong shortcut is
    /// worse than one that displays none.
    public var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        let name = Self.keyName(for: keyCode)
        guard name.count == 1, let character = name.first, character.isLetter
            || character.isNumber || character.isPunctuation || character.isSymbol
        else { return ("", []) }
        return (name.lowercased(), cocoaModifiers)
    }

    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[keyCode] { return special }
        guard
            let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
                .takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return -1
            }
            return UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    private static let specialKeyNames: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        116: "⇞", 121: "⇟", 115: "↖", 119: "↘", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

extension HotKeyID {
    /// Defaults chosen to sit beside the system screenshot shortcuts, not on
    /// top of them.
    ///
    /// macOS owns ⇧⌘3, ⇧⌘4 and ⇧⌘5 and wins silently if we register them, so
    /// the digits start at 1 and 2 — free on a stock system, and adjacent to
    /// the built-ins people already know. Window and repeat keep a Control
    /// prefix because the remaining low digits are all taken.
    public var defaultBinding: HotKeyBinding? {
        switch self {
        case .captureFullscreen:
            HotKeyBinding(keyCode: 18, cocoa: [.shift, .command])                 // ⇧⌘1
        case .captureArea:
            HotKeyBinding(keyCode: 19, cocoa: [.shift, .command])                 // ⇧⌘2
        case .recogniseText:
            HotKeyBinding(keyCode: 31, cocoa: [.shift, .command])                 // ⇧⌘O
        case .captureWindow:
            HotKeyBinding(keyCode: 23, cocoa: [.control, .shift, .command])       // ⌃⇧⌘5
        case .captureScrolling:
            HotKeyBinding(keyCode: 19, cocoa: [.control, .shift, .command])       // ⌃⇧⌘2
        case .captureRepeat:
            HotKeyBinding(keyCode: 22, cocoa: [.control, .shift, .command])       // ⌃⇧⌘6
        default:
            nil
        }
    }

    /// What the defaults were before revision 2, so a migration can tell an
    /// untouched binding from one the user deliberately chose.
    static func legacyDefaultBinding(for id: HotKeyID) -> HotKeyBinding? {
        switch id {
        case .captureArea: HotKeyBinding(keyCode: 21, cocoa: [.control, .shift, .command])
        case .captureFullscreen: HotKeyBinding(keyCode: 20, cocoa: [.control, .shift, .command])
        case .captureWindow: HotKeyBinding(keyCode: 23, cocoa: [.control, .shift, .command])
        case .captureRepeat: HotKeyBinding(keyCode: 22, cocoa: [.control, .shift, .command])
        default: nil
        }
    }
}
