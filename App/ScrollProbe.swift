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
        var out = ["Screen Sculpt scrolling-capture probe", String(repeating: "=", count: 44), ""]
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

        // `--scroll-probe <app>` targets a named application; without it, the
        // frontmost window. Naming one matters when the probe is driven from a
        // terminal, which would otherwise be the window in front.
        let requested = CommandLine.arguments
            .drop { $0 != "--scroll-probe" }.dropFirst().first
        if let requested { out.append("Requested target: \(requested)") }

        guard let target = frontmostScrollable(named: requested) else {
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
        out.append("")
        out += await rewindToTop(region: region, target: target, service: service)
        out.append("")
        out += await fullCapture(region: region, service: service)
        return out
    }

    private static func captureAndScroll(
        region: ScreenRect, target: Target,
        service: ScreenCaptureKitService
    ) async -> [String] {
        var out: [String] = []
        let centre = CGPoint(x: region.midX.value, y: region.midY.value)

        if let owner = WindowLocator.windowOwner(at: centre) {
            out.append("Window under the region centre: \(owner.name) (pid \(owner.pid))")
        } else {
            out.append("Window under the region centre: none — nothing to scroll")
        }

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
                // What it actually moved, against what it was told to. These
                // differ, and the gap is what the stitcher has to search.
                out += measure(from: beforeGray, to: afterGray, commanded: abs(attempt.1))
                driver.scroll(deltaY: -attempt.1, at: centre, to: .systemWide)
                return out
            }
            out.append("  no movement from the HID tap either")
        }

        return out
    }

    /// Collects trace lines from the controller.
    @MainActor
    private final class TraceCollector {
        var lines: [String] = []
    }

    /// Scroll the target back to the start before the real run.
    ///
    /// Otherwise the probe tests whatever position the window happened to be
    /// left in, and a document already at its end has nothing below to capture
    /// — which looks identical to a driver that does not work.
    private static func rewindToTop(
        region: ScreenRect, target: Target, service: ScreenCaptureKitService
    ) async -> [String] {
        let centre = CGPoint(x: region.midX.value, y: region.midY.value)
        let driver = ScrollDriver()
        let original = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(centre)
        defer { if let original { CGWarpMouseCursorPosition(original) } }

        // Which sign moves towards the start is application-dependent, so send
        // both; whichever is backwards does the work and the other is already
        // pinned at its limit.
        for _ in 0..<12 {
            driver.scroll(deltaY: 600, at: centre, to: .systemWide)
            try? await Task.sleep(for: .milliseconds(90))
        }
        try? await Task.sleep(for: .milliseconds(400))
        return ["Rewound the target towards the start of its content."]
    }

    /// Report measured travel against what was asked for.
    private static func measure(
        from before: GrayFrame, to after: GrayFrame, commanded: Int
    ) -> [String] {
        var options = CorrelationOptions()
        options.maximumOffset = after.height - 64
        let forward = ScrollCorrelator.align(
            previous: RowDescriptors(before), next: RowDescriptors(after), options: options
        )
        let backward = ScrollCorrelator.align(
            previous: RowDescriptors(after), next: RowDescriptors(before), options: options
        )

        var out: [String] = []
        out.append("  commanded \(commanded) pt")
        if let forward {
            out.append("  forward:  \(forward.offset) px, \(forward.confidence.rawValue), "
                + "score \(String(format: "%.3f", forward.score))")
        }
        if let backward {
            out.append("  backward: \(backward.offset) px, \(backward.confidence.rawValue), "
                + "score \(String(format: "%.3f", backward.score))")
        }
        return out
    }

    /// Run the real capture, the way the menu item does.
    ///
    /// The stage above only asks whether a scroll event lands. This asks
    /// whether the whole thing works, which is a different question and the one
    /// that was actually reported broken.
    private static func fullCapture(
        region: ScreenRect, service: ScreenCaptureKitService
    ) async -> [String] {
        var out = ["Full capture run:"]
        let controller = ScrollingCaptureController(captureService: service)
        var options = ScrollingCaptureController.Options()
        options.maximumFrames = 6
        let collector = TraceCollector()
        controller.trace = { collector.lines.append("  \($0)") }

        var report: [String] = []
        do {
            let result = try await controller.capture(area: region, options: options) { progress in
                report.append("  frame \(progress.frames) · \(progress.rows) px")
            }
            report.append("  RESULT: \(result.frameCount) frames, \(result.rows) px tall")
            report.append("  offsets: \(result.offsets)")
            if result.stickyBands.top > 0 || result.stickyBands.bottom > 0 {
                report.append("  sticky: top \(result.stickyBands.top), "
                    + "bottom \(result.stickyBands.bottom)")
            }
            for warning in result.warnings { report.append("  warning: \(warning)") }
        } catch {
            report.append("  FAILED: \(error.localizedDescription)")
        }
        out += collector.lines
        out += report
        return out
    }

    /// The frontmost ordinary window belonging to someone else.
    private static func frontmostScrollable(named wanted: String? = nil) -> Target? {
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
            if let wanted, owner.caseInsensitiveCompare(wanted) != .orderedSame { continue }
            return Target(owner: owner, pid: pid, bounds: bounds)
        }
        return nil
    }
}
