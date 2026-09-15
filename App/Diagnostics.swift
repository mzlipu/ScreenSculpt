// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SSCapture
import SSCaptureUI
import SSGeometry
import SSHotKeys
import SSPersistence
import SSPlatform

/// `ScreenSculpt --diagnose` — prints what the app can actually see and exits.
///
/// Permission problems in this app are almost always invisible from outside the
/// process: TCC decisions are keyed to the running binary, so the only place
/// that can answer "is screen recording actually working" is the app itself.
/// Asking a user to paste this output is far more useful than asking them to
/// describe a dialog.
@MainActor
enum Diagnostics {

    /// Synchronous snapshot for the settings window.
    ///
    /// Skips the async capture probe, using the broker's last known state
    /// instead, so opening a settings pane never blocks on ScreenCaptureKit.
    static func report(broker: PermissionBroker) -> String {
        var out = ["ScreenSculpt diagnostics", String(repeating: "=", count: 40), ""]
        out += identitySection()
        out.append("Screen recording: \(broker.screenRecording)")
        out.append("Accessibility:    \(broker.accessibility)")
        out.append("")
        out += trailingSection()
        return out.joined(separator: "\n")
    }

    static func runAndExit() async -> Never {
        var out = ["ScreenSculpt diagnostics", String(repeating: "=", count: 40), ""]
        out += identitySection()
        out += await screenRecordingSection()
        out += trailingSection()
        // Also written to disk, because a diagnostic run from a shell is
        // attributed to the *terminal* by TCC, not to ScreenSculpt — so the
        // permission probes lie unless the app is launched normally. Running
        // `open -n -a ScreenSculpt --args --diagnose` and reading this file is
        // the only way to see what the real app sees.
        let text = out.joined(separator: "\n")
        print(text)
        try? text.write(to: Self.reportURL, atomically: true, encoding: .utf8)
        exit(0)
    }

    /// Where `--diagnose` leaves its report.
    static var reportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ScreenSculpt-diagnostics.txt")
    }

    /// Reports the configured shortcuts and flags any macOS already owns.
    ///
    /// A combination the system holds registers without error and then never
    /// fires, so it is invisible from inside the app — this is where it shows.
    private static func shortcutsSection() -> [String] {
        var out = ["Shortcuts:"]
        let configured = HotKeyCenter.configuredBindings(settings: SettingsStore())
        let systemOwned = Set(HotKeyCenter.systemScreenshotShortcuts())

        for id in HotKeyID.allCases {
            guard let binding = configured[id] else { continue }
            let warning = systemOwned.contains(binding) ? "   ⚠️  macOS owns this" : ""
            out.append("  \(id.label): \(binding.displayString)\(warning)")
        }
        out.append("")
        return out
    }

    private static func identitySection() -> [String] {
        var out: [String] = []

        // Identity — a mismatch here is the usual root cause.
        out.append("Bundle:      \(Bundle.main.bundleIdentifier ?? "?")")
        out.append("Version:     \(AppEnvironment.versionString)")
        out.append("Path:        \(Bundle.main.bundleURL.path)")
        // TCC attributes a permission request to the "responsible process",
        // which for a binary started from a shell is the *terminal*, not this
        // app. The probes below then report a permission fault that does not
        // exist. An attached tty is the reliable tell — an environment variable
        // is not, since `open` inherits the caller's environment.
        if isatty(STDOUT_FILENO) != 0 {
            out.append("Launched by: a terminal")
            out.append("  ⚠️  Screen-recording probes are attributed to the terminal, not")
            out.append("      to ScreenSculpt, so they will under-report. For a true")
            out.append("      reading run:")
            out.append("        open -n -a ScreenSculpt --args --diagnose")
            out.append("      then read \(reportURL.path)")
        } else {
            out.append("Launched by: launchd or Finder (probes are accurate)")
        }
        out.append("Translocated: \(Bundle.main.bundleURL.path.contains("/AppTranslocation/"))")
        out.append("")

        // Copies on disk. When they share a signing certificate they share a
        // designated requirement too, so they no longer compete for the grant —
        // only build artefacts in DerivedData are worth calling out, and only
        // then as noise rather than a fault.
        let copies = NSWorkspace.shared.urlsForApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        out.append("Copies on disk (\(copies.count)):")
        for url in copies {
            let isBuildArtefact = url.path.contains("/DerivedData/")
            out.append("  \(url.path)\(isBuildArtefact ? "   [build artefact]" : "")")
        }
        let installed = copies.filter { !$0.path.contains("/DerivedData/") }
        if installed.count > 1 {
            out.append("  ⚠️  More than one installed copy — keep only /Applications.")
        }
        out.append("")

        out += shortcutsSection()

        out.append("Signature:")
        out.append("  \(codesignSummary())")
        out.append("")
        return out
    }

    private static func screenRecordingSection() async -> [String] {
        var out: [String] = []
        out.append("Screen recording:")
        out.append("  CGPreflightScreenCaptureAccess(): \(CGPreflightScreenCaptureAccess())")

        var shareableWindows = -1
        var titledWindows = -1
        var shareableError: String?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            let own = Bundle.main.bundleIdentifier
            let foreign = content.windows.filter {
                $0.owningApplication?.bundleIdentifier != own
            }
            shareableWindows = foreign.count
            titledWindows = foreign.filter { !($0.title ?? "").isEmpty }.count
        } catch {
            shareableError = "\(error)"
        }
        out.append("  SCShareableContent foreign windows: \(shareableWindows)")
        out.append("  ...with readable titles: \(titledWindows)")
        if let shareableError { out.append("  SCShareableContent error: \(shareableError)") }

        // The decisive probe: actually capture a pixel.
        let captureResult: String
        do {
            let service = ScreenCaptureKitService()
            let result = try await service.capture(
                CaptureRequest(mode: .fullscreen(displayID: nil))
            )
            captureResult = "OK — \(result.image.size) at \(result.image.pixelScale)"
        } catch {
            captureResult = "FAILED — \(error.localizedDescription)"
        }
        out.append("  Actual capture: \(captureResult)")
        out.append("")
        return out
    }

    private static func trailingSection() -> [String] {
        var out: [String] = []

        // Constructing the overlay is a real smoke test, not a formality: a
        // subclass that declares its own designated initialiser without
        // overriding NSWindow's leaves a trapping stub behind, and AppKit calls
        // straight into it. That shipped once and killed the app on every area
        // capture, so it gets checked here.
        out.append("Overlay window: \(SelectionOverlayProbe.canConstruct() ? "OK" : "FAILED")")
        out.append("")

        out.append("Accessibility (only needed for scrolling capture):")
        out.append("  AXIsProcessTrusted(): \(AXIsProcessTrusted())")
        out.append("")

        out.append("Displays:")
        let topology = CocoaBridge.currentTopology()
        for display in topology.displays {
            out.append("  \(display.localizedName ?? "?") id=\(display.displayID) "
                + "\(display.frame) \(display.scale)\(display.isPrimary ? " [primary]" : "")")
        }
        return out
    }

    private static func codesignSummary() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", Bundle.main.bundleURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        let fields = text.split(separator: "\n").filter {
            $0.hasPrefix("Signature") || $0.hasPrefix("CDHash=") || $0.hasPrefix("TeamIdentifier")
        }
        return fields.joined(separator: "  ")
    }
}
