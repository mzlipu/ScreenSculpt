// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSHotKeys
import SSPersistence
import SwiftUI

struct SettingsRootView: View {
    @Bindable var settings: SettingsStore
    let hotKeys: HotKeyCenter
    let permissions: any SettingsPermissionBridge

    var body: some View {
        TabView {
            GeneralPane(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }

            HotkeysPane(hotKeys: hotKeys)
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }

            EditorPane(settings: settings)
                .tabItem { Label("Editor", systemImage: "crop") }

            AdvancedPane(settings: settings)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }

            PermissionsPane(permissions: permissions)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 600, height: 520)
    }
}

// MARK: - General

struct GeneralPane: View {
    @Bindable var settings: SettingsStore
    @State private var folderDisplay = ""

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Screenshots folder") {
                    HStack {
                        Text(settings.screenshotFolder.path)
                            .truncationMode(.head)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .help(settings.screenshotFolder.path)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }

                Picker("Format", selection: binding(Settings.saveFormat)) {
                    ForEach(SaveFormatSetting.allCases) { Text($0.label).tag($0) }
                }
                Text(settings[Settings.saveFormat].detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings[Settings.saveFormat] != .png {
                    Slider(value: binding(Settings.jpegQuality), in: 0.4...1.0) {
                        Text("JPEG quality")
                    }
                }

                Toggle(
                    "Downscale Retina captures to 1×",
                    isOn: binding(Settings.downscaleRetina)
                )
                Text("Halves the pixel dimensions so the file matches the size you measured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Filename") {
                    TextField("", text: binding(Settings.filenameTemplate))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Text("strftime format. %Y year, %m month, %d day, %H%M%S time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("After a capture") {
                Picker("Then", selection: binding(Settings.afterCapture)) {
                    ForEach(AfterCapture.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Window captures") {
                Picker("Background", selection: binding(Settings.windowBackground)) {
                    ForEach(WindowBackground.allCases) { Text($0.label).tag($0) }
                }
                if settings[Settings.windowBackground] == .solid {
                    LabeledContent("Colour") {
                        TextField("#RRGGBB", text: binding(Settings.windowBackgroundColor))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }
                Text("Applies to window captures only, not area or fullscreen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open Screen Sculpt at login", isOn: binding(Settings.launchAtLogin))
                Picker("Mouse pointer", selection: binding(Settings.cursor)) {
                    ForEach(CursorSetting.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<V>(_ key: SettingKey<V>) -> Binding<V> {
        Binding(get: { settings[key] }, set: { settings[key] = $0 })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.screenshotFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings[Settings.screenshotFolder] = url
    }
}

// MARK: - Editor

struct EditorPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Zoom") {
                Picker("Open captures at", selection: binding(Settings.defaultZoom)) {
                    ForEach(DefaultZoom.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show a pixel grid at high zoom", isOn: binding(Settings.showPixelGrid))
                Text("Fades in past 16×, so individual pixels stay countable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window") {
                Toggle("Keep the editor above other windows",
                       isOn: binding(Settings.editorAlwaysOnTop))
            }

            Section("Closing with Escape") {
                Toggle("Copy the image first", isOn: binding(Settings.escapeCopies))
                Toggle("Save the image first", isOn: binding(Settings.escapeSaves))
                Text("Escape always closes the editor. These decide what happens on the way out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<V>(_ key: SettingKey<V>) -> Binding<V> {
        Binding(get: { settings[key] }, set: { settings[key] = $0 })
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @Bindable var settings: SettingsStore

    /// Queried at runtime rather than hardcoded, so the list always matches
    /// what this OS version can actually recognise.
    private var ocrLanguages: [(code: String, label: String)] {
        let codes = [
            "en-US", "fr-FR", "de-DE", "es-ES", "it-IT", "pt-BR", "nl-NL",
            "sv-SE", "da-DK", "nb-NO", "pl-PL", "ro-RO", "cs-CZ", "tr-TR",
            "uk-UA", "ru-RU", "th-TH", "vi-VN", "id-ID", "ms-MY", "ar-SA",
            "ja-JP", "ko-KR", "zh-Hans", "zh-Hant",
        ]
        return codes.map { code in
            (code, Locale.current.localizedString(forIdentifier: code) ?? code)
        }
        .sorted { $0.label < $1.label }
    }

    var body: some View {
        Form {
            Section("Text recognition") {
                Picker("Primary language", selection: binding(Settings.primaryOCRLanguage)) {
                    ForEach(ocrLanguages, id: \.code) { Text($0.label).tag($0.code) }
                }
                Toggle("Remove line breaks from recognised text",
                       isOn: binding(Settings.ocrRemoveLineBreaks))
            }

            Section("Scrolling capture") {
                LabeledContent("Maximum height") {
                    HStack {
                        TextField("", value: binding(Settings.scrollingMaxHeight),
                                  format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("pixels").foregroundStyle(.secondary)
                    }
                }
                Slider(value: doubleBinding(Settings.scrollingSpeed), in: 1...5, step: 1) {
                    Text("Scroll speed")
                }
                Toggle("Reverse the scroll direction",
                       isOn: binding(Settings.reverseScrollDirection))
                Text("Try this if a scroll-modifier utility such as a reverser is installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Toggle("Hide the menu bar icon", isOn: binding(Settings.hideMenuBarIcon))
                Picker("Dock icon", selection: binding(Settings.dockIconMode)) {
                    ForEach(DockIconMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Confirmation", selection: binding(Settings.confirmation)) {
                    ForEach(ConfirmationStyle.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Automation") {
                Toggle("Allow screensculpt:// links", isOn: binding(Settings.urlSchemeEnabled))
                Text("Lets Raycast, Alfred and Shortcuts trigger captures. Off by default, "
                     + "because any application on this Mac could then drive Screen Sculpt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Reset all settings…", role: .destructive, action: confirmReset)
                Text("Keeps your permission approvals and saved screenshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<V>(_ key: SettingKey<V>) -> Binding<V> {
        Binding(get: { settings[key] }, set: { settings[key] = $0 })
    }

    private func doubleBinding(_ key: SettingKey<Int>) -> Binding<Double> {
        Binding(get: { Double(settings[key]) }, set: { settings[key] = Int($0) })
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Every preference returns to its default. "
            + "Your screenshots and permission approvals are untouched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { settings.resetAll() }
    }
}
