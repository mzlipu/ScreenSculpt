// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSPlatform
import SSSettingsUI

/// Adapts `PermissionBroker` to what the settings window needs.
///
/// The settings module deliberately knows nothing about ScreenCaptureKit; it
/// asks this for two strings and four actions. Keeping the boundary here means
/// the permission logic stays testable and the UI stays replaceable.
@MainActor
final class PermissionBridge: SettingsPermissionBridge {

    private let broker: PermissionBroker
    private var screenRecordingState: PermissionState = .notDetermined
    private var accessibilityState: PermissionState = .notDetermined

    init(broker: PermissionBroker) {
        self.broker = broker
    }

    func refresh() async {
        screenRecordingState = await broker.refreshScreenRecording()
        accessibilityState = broker.refreshAccessibility()
    }

    var screenRecordingSummary: String { Self.describe(screenRecordingState) }
    var accessibilitySummary: String { Self.describe(accessibilityState) }

    func openScreenRecordingSettings() { broker.openSettings(for: .screenRecording) }
    func openAccessibilitySettings() { broker.openSettings(for: .accessibility) }
    func relaunch() { broker.relaunch() }

    func runDiagnostics() -> String {
        // Reuses the same probes as `--diagnose`, so the text a user pastes from
        // the settings window and the text they get from the terminal cannot
        // drift apart.
        Diagnostics.report(broker: broker)
    }

    private static func describe(_ state: PermissionState) -> String {
        switch state {
        case .granted: "Granted and working"
        case .notDetermined: "Not yet requested"
        case .denied: "Denied — enable it in System Settings"
        case .needsRelaunch: "Granted — reopen Screen Sculpt to apply it"
        case .staleGrant: "Approved, but recorded against an older build"
        }
    }
}
