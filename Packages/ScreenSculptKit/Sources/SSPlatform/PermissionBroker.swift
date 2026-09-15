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

    /// TCC service name, for `tccutil reset`.
    public var tccService: String {
        self == .screenRecording ? "ScreenCapture" : "Accessibility"
    }
}

public enum PermissionState: Equatable, Sendable {
    /// Verified by actually capturing a pixel.
    case granted

    /// Never asked. Prompting is worth a try.
    case notDetermined

    /// Asked, refused, and the system prompt will not appear again.
    case denied

    /// The grant exists but this *process* cannot use it.
    ///
    /// macOS applies a screen-recording grant at process start, so approving it
    /// while the app is running changes nothing until the app restarts. This is
    /// the most common "but I already enabled it!" case, and the fix is a
    /// relaunch, not another prompt.
    case needsRelaunch

    /// The grant is recorded against a different build and no longer matches
    /// this one, so macOS shows it enabled while refusing it.
    ///
    /// With an ad-hoc signature the designated requirement is the binary's
    /// cdhash, which changes on every build. Signing with a certificate makes
    /// the requirement stable; see scripts/make-signing-cert.sh.
    case staleGrant

    public var isUsable: Bool { self == .granted }
}

/// Checks and requests the two permissions the app needs.
///
/// Both are requested lazily, when a feature needs them — never at launch. For a
/// screen-capture utility that also wants Accessibility, prompting on first run
/// reads as overreach.
@MainActor
public final class PermissionBroker {

    public private(set) var screenRecording: PermissionState = .notDetermined
    public private(set) var accessibility: PermissionState = .notDetermined

    /// Whether this app identity has ever shown the system prompt.
    ///
    /// macOS shows it exactly once and silently ignores later calls, so asking
    /// again produces either a dialog the user already answered or nothing at
    /// all — which looks like the app is broken.
    private let promptedKey = "permissions.screenRecording.didPrompt"
    private var hasPrompted: Bool {
        get { UserDefaults.standard.bool(forKey: promptedKey) }
        set { UserDefaults.standard.set(newValue, forKey: promptedKey) }
    }

    /// The build that last captured successfully, so a changed binary is
    /// distinguishable from a merely-restarted one.
    private let grantedBuildKey = "permissions.screenRecording.grantedForBuild"

    public init() {}

    // MARK: - Screen Recording

    /// Determine the real state by trying to capture, not by asking.
    ///
    /// `CGPreflightScreenCaptureAccess()` is not trustworthy alone: it reads the
    /// TCC record, so it keeps returning true for a grant that no longer applies
    /// to this process or this binary while every capture comes back empty. A
    /// two-pixel capture is cheap and unambiguous.
    @discardableResult
    public func refreshScreenRecording() async -> PermissionState {
        if await canActuallyCapture() {
            screenRecording = .granted
            UserDefaults.standard.set(currentBuild, forKey: grantedBuildKey)
            return screenRecording
        }

        if CGPreflightScreenCaptureAccess() {
            // The system says yes but we cannot capture. Either the grant was
            // given after this process launched, or it belongs to a different
            // build. Distinguish them, because the remedies differ.
            let granted = UserDefaults.standard.string(forKey: grantedBuildKey)
            screenRecording = (granted != nil && granted != currentBuild)
                ? .staleGrant
                : .needsRelaunch
        } else {
            screenRecording = hasPrompted ? .denied : .notDetermined
        }
        return screenRecording
    }

    /// Two-pixel capture. Succeeds only if the permission genuinely works.
    private func canActuallyCapture() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first else { return false }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.showsCursor = false
            _ = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
            return true
        } catch {
            return false
        }
    }

    /// Show the system prompt, at most once for this app identity.
    ///
    /// Returns false when it has already been shown, so callers route the user
    /// to Settings rather than firing a dialog that will never appear.
    @discardableResult
    public func requestScreenRecording() -> Bool {
        guard !hasPrompted else { return false }
        hasPrompted = true
        return CGRequestScreenCaptureAccess()
    }

    public var canStillPrompt: Bool { !hasPrompted }

    private var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    // MARK: - Accessibility

    @discardableResult
    public func refreshAccessibility() -> PermissionState {
        accessibility = AXIsProcessTrusted() ? .granted : .notDetermined
        return accessibility
    }

    /// `NSAccessibilityUsageDescription` is not displayed on macOS — the prompt
    /// wording is fixed — which is why the app explains itself first.
    @discardableResult
    public func requestAccessibility() -> Bool {
        // kAXTrustedCheckOptionPrompt is imported as a `var`, which Swift 6
        // rejects as shared mutable state. Its value is a stable constant.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibility = trusted ? .granted : .notDetermined
        return trusted
    }

    // MARK: - Recovery

    public func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// Quit and start a fresh copy — the fix for `.needsRelaunch`.
    ///
    /// Worth doing for the user rather than asking them to do it by hand, since
    /// it is the single most common remedy.
    public func relaunch() {
        let path = Bundle.main.bundleURL.path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit first, or LaunchServices simply focuses
        // the copy that is already running instead of starting a new one.
        task.arguments = ["-c", "sleep 1; open -n \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Other copies of this app on disk.
    ///
    /// Unless both were signed with the same certificate, two copies have two
    /// different signatures, so a grant given to one does nothing for the other
    /// — while both appear as "ScreenSculpt" in System Settings.
    public func duplicateInstallations() -> [URL] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        let all = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
        let current = Bundle.main.bundleURL.standardizedFileURL
        return all.map(\.standardizedFileURL).filter { $0 != current }
    }

    /// True when running from a randomised read-only mount, which happens when
    /// the app is launched straight from a DMG or from ~/Downloads.
    public var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    /// The command that clears a stuck TCC record outright.
    public func resetCommand(for kind: PermissionKind) -> String {
        "tccutil reset \(kind.tccService) \(Bundle.main.bundleIdentifier ?? "")"
    }

    /// What to tell the user, and what they should do about it.
    public func advice(for kind: PermissionKind) -> String {
        let state = kind == .screenRecording ? screenRecording : accessibility
        switch state {
        case .granted:
            return "Granted and working."

        case .notDetermined:
            return "ScreenSculpt has not asked for this yet."

        case .denied:
            return """
                Permission was declined, and macOS will not ask again.

                Enable ScreenSculpt in System Settings → Privacy & Security → \
                Screen & System Audio Recording, then quit and reopen the app.
                """

        case .needsRelaunch:
            return """
                The permission is granted, but macOS only applies it when an app \
                starts — and this copy was already running when you approved it.

                Quitting and reopening ScreenSculpt will fix it.
                """

        case .staleGrant:
            var text = """
                System Settings shows ScreenSculpt as approved, but macOS is \
                refusing it because that approval belongs to an earlier build.

                In System Settings → Privacy & Security → Screen & System Audio \
                Recording, remove ScreenSculpt with the − button, add this copy \
                again, then reopen the app.

                If that does not help, clear the record outright:
                    \(resetCommand(for: kind))
                """
            let duplicates = duplicateInstallations()
            if !duplicates.isEmpty {
                text += "\n\nAnother copy of ScreenSculpt is on disk, "
                text += "which is the likely cause:\n"
                text += duplicates.map { "  • \($0.path)" }.joined(separator: "\n")
            }
            return text
        }
    }
}
