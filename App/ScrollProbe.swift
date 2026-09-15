// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation
import SSCapture
import SSGeometry
import SSImaging
import SSPlatform
import SSStitch

/// Runs the scrolling-capture driver against whatever window is in front and
/// reports each stage.
///
/// Scroll synthesis cannot be unit tested — it needs Accessibility, a window
/// server and a real application to scroll — so this exists to answer, on a
/// real machine, which stage actually fails. Every step reports what it saw
/// rather than only whether it succeeded, because "nothing happened" is the
/// one symptom that fits all of them.
@MainActor
enum ScrollProbe {

    /// A window worth trying to scroll.
    private struct Target {
        let owner: String
        let pid: pid_t
        let bounds: CGRect
    }

    static var reportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ScreenSculpt-scroll-probe.txt")
    }

    static func runAndExit() async -> Never {
        var out = ["ScreenSculpt scrolling-capture probe", String(repeating: "=", count: 44), ""]
        out += await probe()
        let text = out.joined(separator: "\n")
        print(text)
        try? text.write(to: Self.reportURL, atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func probe() async -> [String] {
        var out: [String] = []

        out.append("Accessibility trusted: \(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            out.append("")
            out.append("  Stop. Without this, no scroll event can be delivered.")
            out.append("  Grant it to \(Bundle.main.bundleURL.path)")
            return out
        }

        guard let target = frontmostScrollable() else {
            out.append("No other application's window found to scroll.")
            return out
        }
        out.append("Target: \(target.owner) (pid \(target.pid))")
        out.append("Bounds: \(target.bounds)")
        out.append("")

        // Work on the middle of the window, away from toolbars and footers.
        let inset = target.bounds.insetBy(dx: 20, dy: 60)
        guard inset.height >= 200 else {
            out.append("The window is too short to scroll meaningfully.")
            return out
        }
        let region = ScreenRect(
            x: LogicalPt(inset.minX), y: LogicalPt(inset.minY),
            width: LogicalPt(inset.width), height: LogicalPt(inset.height)
        )

        let service = ScreenCaptureKitService()
        out += await captureAndScroll(region: region, target: target, service: service)
        return out
    }

    private static func captureAndScroll(
        region: ScreenRect, target: Target,
        service: ScreenCaptureKitService
    ) async -> [String] {
        var out: [String] = []
        let centre = CGPoint(x: region.midX.value, y: region.midY.value)

        out.append("Window under the region centre: "
            + "\(WindowLocator.processOwningWindow(at: centre).map(String.init) ?? "none")")

        guard let before = try? await service.capture(CaptureRequest(mode: .area(region))),
              let beforeGray = GrayFrame(before.image.cgImage)
        else {
            out.append("Could not capture the region — check Screen Recording.")
            return out
        }
        out.append("Captured \(beforeGray.width)×\(beforeGray.height) "
            + "at \(before.provenance.pixelScale)")
        out.append("")

        let step = Int(region.height.value * 0.7)
        let driver = ScrollDriver()

        for attempt in [("downward (negative)", -step), ("upward (positive)", step)] {
            out.append("Posting \(attempt.0), \(abs(attempt.1)) pt, to pid \(target.pid)")
            driver.scroll(deltaY: attempt.1, at: centre, to: .process(target.pid))
            try? await Task.sleep(for: .milliseconds(700))

            guard let after = try? await service.capture(CaptureRequest(mode: .area(region))),
                  let afterGray = GrayFrame(after.image.cgImage)
            else {
                out.append("  second capture failed")
                continue
            }

            if beforeGray.matches(afterGray) {
                out.append("  the page did not move")
            } else {
                let alignment = ScrollCorrelator.align(
                    previous: RowDescriptors(beforeGray), next: RowDescriptors(afterGray)
                )
                if let alignment {
                    out.append("  MOVED — measured \(alignment.offset) px, "
                        + "confidence \(alignment.confidence.rawValue)")
                } else {
                    out.append("  the image changed but no offset could be measured")
                }
                // Put it back so the probe leaves no trace.
                driver.scroll(deltaY: -attempt.1, at: centre, to: .process(target.pid))
                return out
            }

            // Same command again, this time as hardware input.
            driver.scroll(deltaY: attempt.1, at: centre, to: .systemWide)
            try? await Task.sleep(for: .milliseconds(700))
            if let after = try? await service.capture(CaptureRequest(mode: .area(region))),
               let afterGray = GrayFrame(after.image.cgImage),
               !beforeGray.matches(afterGray) {
                out.append("  MOVED via the HID tap, but not when posted to the process")
                driver.scroll(deltaY: -attempt.1, at: centre, to: .systemWide)
                return out
            }
            out.append("  no movement from the HID tap either")
        }

        return out
    }

    /// The frontmost ordinary window belonging to someone else.
    private static func frontmostScrollable() -> Target? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        let mine = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != mine,
                let owner = window[kCGWindowOwnerName as String] as? String,
                let raw = window[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                bounds.height > 300, bounds.width > 300
            else { continue }
            return Target(owner: owner, pid: pid, bounds: bounds)
        }
        return nil
    }
}
