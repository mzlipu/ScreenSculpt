// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSPersistence
import SwiftUI

/// Who made this, which version it is, and where to go next.
///
/// More than a credit. For an app distributed outside the App Store this is the
/// page that answers the questions a cautious user actually has — what it is,
/// who wrote it, what licence it carries, whether it phones home — and the one
/// that has to supply a version string when someone reports a bug. A name on
/// its own would look like a signature on an otherwise anonymous binary.
struct AboutPane: View {

    let settings: SettingsStore

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Version \(short) (build \(build))"
    }

    private var icon: NSImage? {
        NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 4) {
                    Text("Screen Sculpt")
                        .font(.system(size: 22, weight: .semibold))
                    Text(version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Text(
                    "A screenshot tool for people who need the pixels to be right: "
                        + "scrolling capture, measurement, colour and contrast, and text "
                        + "recognition."
                )
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)

                Divider().padding(.horizontal, 60)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    row("Created by", "Muiduzzaman Lipu")
                    row("Licence", "Apache-2.0")
                    row("Privacy", "No accounts, no telemetry, nothing leaves this Mac")
                }
                .font(.callout)

                Divider().padding(.horizontal, 60)

                // Practical rather than decorative: the first is what a bug
                // report needs, the second is where support questions go.
                HStack(spacing: 12) {
                    Button("Copy Diagnostics") { copyDiagnostics() }
                    Button("Open Screenshots Folder") { openScreenshots() }
                }

                Text("© 2026 Muiduzzaman Lipu. Made in Bangladesh.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    /// Put the version and system details on the clipboard.
    ///
    /// Bug reports arrive without them otherwise, and the follow-up question is
    /// always the same one.
    private func copyDiagnostics() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let summary = """
            Screen Sculpt \(version)
            macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
            \(archDescription)
            Bundle: \(Bundle.main.bundleIdentifier ?? "unknown")
            Path: \(Bundle.main.bundleURL.path)
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    private var archDescription: String {
        #if arch(arm64)
        "Apple silicon"
        #else
        "Intel"
        #endif
    }

    /// The folder the app is actually configured to save into — not Pictures,
    /// which is merely where it starts out.
    private func openScreenshots() {
        NSWorkspace.shared.open(settings.screenshotFolder)
    }
}
