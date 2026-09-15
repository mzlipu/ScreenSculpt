// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSPlatform

/// Explains permission problems and offers the action that actually fixes each
/// one.
///
/// Split out of `AppEnvironment` because the permission story for a
/// screen-capture app is genuinely involved — five distinct states, each with a
/// different remedy — and mixing it with capture orchestration made both harder
/// to follow.
@MainActor
enum PermissionPresenter {

    /// Screen Recording is requested lazily, on first capture — never at
    /// launch. Asking a screenshot utility's worth of permissions before the
    /// user has done anything reads as overreach.
    static func ensureScreenRecording(_ permissions: PermissionBroker) async -> Bool {
        switch await permissions.refreshScreenRecording() {
        case .granted:
            return true

        case .notDetermined:
            // The system prompt appears once per app identity. If it has already
            // been shown, requestScreenRecording() returns false rather than
            // firing a dialog that will never appear.
            if permissions.requestScreenRecording(),
               await permissions.refreshScreenRecording() == .granted {
                return true
            }
            present(permissions,
                title: "ScreenSculpt needs permission to record the screen",
                body: """
                    Enable ScreenSculpt in System Settings → Privacy & Security \
                    → Screen & System Audio Recording.

                    macOS only applies the permission when an app starts, so \
                    reopen ScreenSculpt afterwards.
                    """,
                offerRelaunch: true
            )
            return false

        case .needsRelaunch:
            // The common case: approved while the app was already running.
            // Another prompt would achieve nothing; a restart is the fix.
            present(permissions,
                title: "Almost there — ScreenSculpt needs to restart",
                body: permissions.advice(for: .screenRecording),
                offerRelaunch: true,
                relaunchIsPrimary: true
            )
            return false

        case .denied:
            present(permissions,
                title: "Screen recording is turned off",
                body: permissions.advice(for: .screenRecording),
                offerRelaunch: true
            )
            return false

        case .staleGrant:
            present(permissions,
                title: "macOS is not honouring the screen recording permission",
                body: permissions.advice(for: .screenRecording),
                offerRelaunch: true
            )
            return false
        }
    }

    static func present(
        _ permissions: PermissionBroker,
        title: String,
        body: String,
        offerRelaunch: Bool = false,
        relaunchIsPrimary: Bool = false
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning

        // The first button is the default, so it should be whichever action
        // actually resolves the situation.
        if relaunchIsPrimary {
            alert.addButton(withTitle: "Relaunch ScreenSculpt")
            alert.addButton(withTitle: "Open System Settings")
        } else {
            alert.addButton(withTitle: "Open System Settings")
            if offerRelaunch { alert.addButton(withTitle: "Relaunch ScreenSculpt") }
        }
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if relaunchIsPrimary {
            if response == .alertFirstButtonReturn { permissions.relaunch() }
            if response == .alertSecondButtonReturn {
                permissions.openSettings(for: .screenRecording)
            }
        } else {
            if response == .alertFirstButtonReturn {
                permissions.openSettings(for: .screenRecording)
            }
            if offerRelaunch, response == .alertSecondButtonReturn { permissions.relaunch() }
        }
    }
}
