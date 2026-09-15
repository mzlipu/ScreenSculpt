// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SSCapture
import SSGeometry
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

    static func runAndExit() async -> Never {
        var out = ["ScreenSculpt diagnostics", String(repeating: "=", count: 40), ""]
        out += identitySection()
        out += await screenRecordingSection()
        out += trailingSection()
        print(out.joined(separator: "\n"))
        exit(0)
    }

    private static func identitySection() -> [String] {
        var out: [String] = []

        // Identity — a mismatch here is the usual root cause.
        out.append("Bundle:      \(Bundle.main.bundleIdentifier ?? "?")")
        out.append("Version:     \(AppEnvironment.versionString)")
        out.append("Path:        \(Bundle.main.bundleURL.path)")
        out.append("Translocated: \(Bundle.main.bundleURL.path.contains("/AppTranslocation/"))")
        out.append("")

        // Every copy on disk. Two copies with an ad-hoc signature means two
        // different cdhashes, so a grant given to one does nothing for the
        // other — while both appear as "ScreenSculpt" in System Settings.
        let copies = NSWorkspace.shared.urlsForApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        )
        out.append("Copies on disk (\(copies.count)):")
        for url in copies { out.append("  \(url.path)") }
        if copies.count > 1 {
            out.append("  ⚠️  More than one copy. Delete all but /Applications.")
        }
        out.append("")

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
