// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum PermissionKind: Sendable {
    case screenRecording
    case accessibility

    public var settingsURL: URL {
        switch self {
        case .screenRecording:
            URL(string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            URL(string: "x-apple.systempreferences:"
                + "com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

public enum PermissionState: Equatable, Sendable {
    case granted
    case notDetermined
    case denied

    /// macOS believes the permission is granted but the window server is not
    /// honouring it. Almost always a stale TCC record: the app was moved after
    /// being approved, or there are two copies on disk, or it was replaced by a
    /// build with a different signature.
    ///
    /// Distinguishing this from plain `.denied` matters, because the fix is
    /// different — the user has to *remove* the existing entry and re-add it,
    /// and toggling the checkbox is often not enough.
    case staleGrant

    public var isUsable: Bool { self == .granted }
}

/// Checks and requests the two permissions the app needs.
///
/// Both are requested lazily, at the moment a feature needs them — never at
/// launch. For a screen-capture utility that asks for Accessibility as well,
/// prompting on first run reads as overreach and costs more installs than it
/// saves clicks.
@MainActor
public final class PermissionBroker {

    public private(set) var screenRecording: PermissionState = .notDetermined
    public private(set) var accessibility: PermissionState = .notDetermined

    public init() {}

    // MARK: - Screen Recording

    /// Determine the real state using three independent probes.
    ///
    /// `CGPreflightScreenCaptureAccess()` alone is not trustworthy: it keeps
    /// returning true against a stale TCC record while every capture comes back
    /// black. The window-title probe is the reliable tell, because titles of
    /// other applications' windows are exactly what the grant unlocks.
    @discardableResult
    public func refreshScreenRecording() async -> PermissionState {
        let preflight = CGPreflightScreenCaptureAccess()

        // Probe: can we see other applications' windows, and their titles?
        let ownBundleID = Bundle.main.bundleIdentifier
        var sawForeignWindow = false
        var sawForeignTitle = false

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            for window in content.windows {
                guard let owner = window.owningApplication?.bundleIdentifier,
                      owner != ownBundleID else { continue }
                sawForeignWindow = true
                if let title = window.title, !title.isEmpty { sawForeignTitle = true; break }
            }
        } catch {
            // SCStreamError.userDeclined and friends land here.
            screenRecording = preflight ? .staleGrant : .denied
            return screenRecording
        }

        switch (preflight, sawForeignWindow, sawForeignTitle) {
        case (true, _, true):
            screenRecording = .granted
        case (true, true, false), (true, false, false):
            // The system says yes but we can see no titles — the classic stale
            // grant. A relaunch usually fixes it; removing and re-adding the
            // entry always does.
            screenRecording = .staleGrant
        case (false, _, true):
            // Unexpected but harmless: we can evidently read the screen.
            screenRecording = .granted
        default:
            screenRecording = .notDetermined
        }
        return screenRecording
    }

    /// Show the system prompt. Only ever fires once per app identity; after
    /// that macOS silently does nothing and the user must go to Settings.
    @discardableResult
    public func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Accessibility

    @discardableResult
    public func refreshAccessibility() -> PermissionState {
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        return accessibility
    }

    /// Prompts with the system dialog. Note `NSAccessibilityUsageDescription`
    /// is not displayed on macOS — the prompt text is fixed and cannot be
    /// customised, which is why the app explains the reason in its own UI first.
    @discardableResult
    public func requestAccessibility() -> Bool {
        // kAXTrustedCheckOptionPrompt is imported as a `var`, which Swift 6
        // rejects as shared mutable state. The key's value is a documented,
        // stable constant, so spell it out rather than weakening isolation.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibility = trusted ? .granted : .notDetermined
        return trusted
    }

    // MARK: - Recovery

    public func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// Other copies of this app on disk.
    ///
    /// Duplicate installs are the single most common cause of a stale grant:
    /// macOS approved one copy, and you are running the other.
    public func duplicateInstallations() -> [URL] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        let all = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        let current = Bundle.main.bundleURL.standardizedFileURL
        return all.map(\.standardizedFileURL).filter { $0 != current }
    }

    /// True when running from a randomised read-only mount, which happens if
    /// the app is launched straight from a DMG or from `~/Downloads`.
    ///
    /// In this state preferences may not persist and updates cannot install, so
    /// it is worth prompting the user to move the app to /Applications.
    public var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    /// Human-readable explanation and next step for the current state.
    public func advice(for kind: PermissionKind) -> String {
        let state = kind == .screenRecording ? screenRecording : accessibility
        switch state {
        case .granted:
            return "Granted."
        case .notDetermined:
            return "ScreenSculpt needs this permission. Approve the prompt, or\n"
                + "enable it in System Settings."
        case .denied:
            return "Permission was declined. Enable ScreenSculpt in\n"
                + "System Settings → Privacy & Security."
        case .staleGrant:
            var text = """
                macOS lists ScreenSculpt as approved but is not honouring it. \
                This happens when the app is moved or updated after being approved.

                In System Settings → Privacy & Security → Screen & System Audio Recording, \
                remove ScreenSculpt with the − button, then add it again and relaunch.
                """
            let duplicates = duplicateInstallations()
            if !duplicates.isEmpty {
                text += "\n\nAnother copy of ScreenSculpt is on disk, which is the likely cause:\n"
                text += duplicates.map { "  • \($0.path)" }.joined(separator: "\n")
            }
            return text
        }
    }
}
