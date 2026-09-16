// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

// MARK: - Enumerations

public enum SaveFormatSetting: String, Sendable, CaseIterable, Identifiable {
    case auto, png, jpeg
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Automatic (PNG or JPEG)"
        case .png: "PNG"
        case .jpeg: "JPEG"
        }
    }
    public var detail: String {
        switch self {
        case .auto: "PNG for interfaces, JPEG for photographic content."
        case .png: "Lossless. Larger for photographs."
        case .jpeg: "Smaller, but lossy — text edges will soften."
        }
    }
}

public enum WindowBackground: String, Sendable, CaseIterable, Identifiable {
    case wallpaper, transparent, solid, trimShadow
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .wallpaper: "Desktop wallpaper"
        case .transparent: "Transparent"
        case .solid: "Solid colour"
        case .trimShadow: "Trim the shadow"
        }
    }
}

/// When the app appears in the Dock.
///
/// A capture utility spends most of its life with nothing on screen, and a Dock
/// icon for an app with no window is a tile that does nothing when clicked. But
/// once an editor is open there is a real window, and an app with a window and
/// no Dock icon cannot be reached with Command-Tab — so the presence follows
/// the windows rather than being fixed either way.
public enum DockIconMode: String, Sendable, CaseIterable, Identifiable {
    case automatic, always, never
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: "Only while a window is open"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

public enum AfterCapture: String, Sendable, CaseIterable, Identifiable {
    case editor, copyAndSave, copyOnly, saveOnly
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .editor: "Open the editor"
        case .copyAndSave: "Copy and save, no editor"
        case .copyOnly: "Copy to the clipboard only"
        case .saveOnly: "Save to the folder only"
        }
    }
    public var opensEditor: Bool { self == .editor }
    public var copies: Bool { self == .copyAndSave || self == .copyOnly }
    public var saves: Bool { self == .copyAndSave || self == .saveOnly }
}

public enum CursorSetting: String, Sendable, CaseIterable, Identifiable {
    case exclude, include
    public var id: String { rawValue }
    public var label: String {
        self == .exclude ? "Hide the pointer" : "Include the pointer"
    }
}

public enum ConfirmationStyle: String, Sendable, CaseIterable, Identifiable {
    case menuBar, none
    public var id: String { rawValue }
    public var label: String {
        self == .menuBar ? "Flash the menu bar icon" : "No confirmation"
    }
}

public enum DefaultZoom: String, Sendable, CaseIterable, Identifiable {
    case fit, actualSize
    public var id: String { rawValue }
    public var label: String {
        self == .fit ? "Fit the window" : "Actual size (100%)"
    }
}

// MARK: - The registry

/// Every preference in one place.
///
/// Keys are stable strings because they are also the `defaults write` interface;
/// renaming one silently resets that preference for existing users.
public enum Settings {

    // General — capture and output
    public static let screenshotFolder = SettingKey<URL?>(bookmark: "screenshotFolder")
    public static let saveFormat = SettingKey("saveFormat", default: SaveFormatSetting.auto)
    public static let jpegQuality = SettingKey("jpegQuality", default: 0.9)
    public static let downscaleRetina = SettingKey("downscaleRetina", default: false)
    public static let afterCapture = SettingKey("afterCapture", default: AfterCapture.editor)
    public static let filenameTemplate = SettingKey(
        "filenameTemplate", default: "SCR-%Y%m%d-%H%M%S"
    )

    // General — window capture
    public static let windowBackground = SettingKey(
        "windowBackground", default: WindowBackground.trimShadow
    )
    public static let windowBackgroundColor = SettingKey(
        "windowBackgroundColor", default: "#C4C6C8"
    )
    public static let includeWindowShadow = SettingKey("includeWindowShadow", default: false)

    // General — behaviour
    public static let launchAtLogin = SettingKey("launchAtLogin", default: false)
    public static let cursor = SettingKey("captureCursor", default: CursorSetting.exclude)
    public static let delayedCaptureSeconds = SettingKey("delayedCaptureSeconds", default: 3)

    // Editor
    public static let defaultZoom = SettingKey("defaultZoom", default: DefaultZoom.fit)
    public static let editorAlwaysOnTop = SettingKey("editorAlwaysOnTop", default: false)
    public static let showPixelGrid = SettingKey("showPixelGrid", default: true)
    public static let escapeCopies = SettingKey("escapeCopies", default: false)
    public static let escapeSaves = SettingKey("escapeSaves", default: false)

    // Advanced
    public static let primaryOCRLanguage = SettingKey("primaryOCRLanguage", default: "en-US")
    public static let ocrRemoveLineBreaks = SettingKey("ocrRemoveLineBreaks", default: false)
    public static let hideMenuBarIcon = SettingKey("hideMenuBarIcon", default: false)
    public static let dockIconMode = SettingKey(
        "dockIconMode", default: DockIconMode.automatic
    )
    public static let confirmation = SettingKey(
        "confirmationStyle", default: ConfirmationStyle.menuBar
    )
    public static let urlSchemeEnabled = SettingKey("urlSchemeEnabled", default: false)
    public static let scrollingMaxHeight = SettingKey("scrollingMaxHeight", default: 20_000)
    public static let scrollingSpeed = SettingKey("scrollingSpeed", default: 2)
    public static let reverseScrollDirection = SettingKey(
        "reverseScrollDirection", default: false
    )

    /// Schema version, so a future migration has something to branch on.
    /// Cheap now, miserable to retrofit.
    public static let schemaVersion = SettingKey("schemaVersion", default: 1)
}
