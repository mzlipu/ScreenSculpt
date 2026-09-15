// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SwiftUI

/// Permission status and the recovery actions for each failure mode.
///
/// A whole pane for two permissions looks excessive until you have watched
/// someone stare at a ticked checkbox while the app insists it has no access.
/// Diagnosing that from outside the process is impossible — TCC decisions are
/// keyed to the running binary — so the app has to be able to explain itself.
struct PermissionsPane: View {
    let permissions: any SettingsPermissionBridge

    @State private var screenRecording = "Checking…"
    @State private var accessibility = "Checking…"
    @State private var diagnostics: String?

    var body: some View {
        Form {
            Section("Screen Recording") {
                LabeledContent("Status", value: screenRecording)
                Text("Required for every capture. macOS gates all screen pixels behind it, "
                     + "and no application can work around that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open System Settings") {
                        permissions.openScreenRecordingSettings()
                    }
                    Button("Relaunch ScreenSculpt") { permissions.relaunch() }
                        .help("macOS applies this permission only when an app starts.")
                }
            }

            Section("Accessibility") {
                LabeledContent("Status", value: accessibility)
                Text("Only needed for automatic scrolling capture, which sends scroll "
                     + "events to the window being captured. Manual scrolling capture "
                     + "needs no permission at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") { permissions.openAccessibilitySettings() }
            }

            Section("Diagnostics") {
                Text("Reports what this build can actually see, including every copy of "
                     + "ScreenSculpt on disk. Worth attaching to a bug report.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Run diagnostics") { diagnostics = permissions.runDiagnostics() }
                    if diagnostics != nil {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnostics ?? "", forType: .string)
                        }
                    }
                }
                if let diagnostics {
                    ScrollView {
                        Text(diagnostics)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        await permissions.refresh()
        screenRecording = permissions.screenRecordingSummary
        accessibility = permissions.accessibilitySummary
    }
}
