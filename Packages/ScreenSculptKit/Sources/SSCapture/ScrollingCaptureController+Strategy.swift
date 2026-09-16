// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import SSPlatform
import SSStitch

/// Working out how to scroll a particular window.
///
/// Separated from the capture loop because it answers a different question.
/// The loop assumes scrolling works; this is what establishes that it does, and
/// what to do when the obvious way does not.
extension ScrollingCaptureController {

    // MARK: - Finding a scroll that works

    /// How a scroll is delivered.
    /// One way of delivering a scroll, out of the several that have to be tried.
    struct Method {
        enum Delivery {
            /// Straight into one application's queue. Tried first: the target
            /// need not be frontmost and the cursor is never touched.
            case toProcess(pid_t)
            /// As though from the hardware, with the cursor moved over the
            /// target. Reaches applications that route their own input.
            case hardware
        }

        let delivery: Delivery
        let granularity: ScrollDriver.Granularity

        var name: String {
            let route = switch delivery {
            case .toProcess(let pid): "posted to pid \(pid)"
            case .hardware: "hardware tap"
            }
            return "\(route) (\(granularity == .pixels ? "pixels" : "lines"))"
        }
    }

    struct WorkingScroll {
        let method: Method
        let direction: Int
        let frame: RasterImage
    }

    /// What a probe needs to know about the region it is working on.
    struct Probe {
        let area: ScreenRect
        let centre: CGPoint
        let owner: WindowLocator.Owner?
        let step: Int
        let first: RasterImage
    }

    /// Try each way of scrolling until the page actually moves the right way.
    ///
    /// Neither half of this is knowable in advance. Whether an application
    /// accepts a posted event is a property of how it reads input, and which
    /// sign scrolls downward cannot be assumed either — synthesised events do
    /// not pass through the system's natural-scrolling flip. So the first burst
    /// is a probe, and the answer is measured rather than predicted.
    func findWorkingScroll(
        _ probe: Probe, options: Options
    ) async throws -> WorkingScroll? {
        // Ordered least to most intrusive, and within that, modern before
        // legacy. No single combination works everywhere: measured on macOS 26,
        // Notes moves for a phased pixel gesture through the hardware tap and
        // ignores the same event posted to it, while TextEdit ignores pixel
        // gestures altogether and needs plain wheel clicks.
        var methods: [Method] = []
        if let pid = probe.owner?.pid {
            methods.append(Method(delivery: .toProcess(pid), granularity: .pixels))
            methods.append(Method(delivery: .toProcess(pid), granularity: .lines))
        }
        methods.append(Method(delivery: .hardware, granularity: .pixels))
        methods.append(Method(delivery: .hardware, granularity: .lines))
        movedBackwardsOnly = false

        // Probe with a reduced movement and undo it. Calibration happens before
        // the capture starts, so whatever it disturbs is disturbance to the
        // user's starting position — but too small a step leaves the two
        // directions scoring alike, and the choice becomes a coin flip.
        let step = max(120, probe.step / 2)

        // A direction accepted on weak evidence is worse than none: it commits
        // the whole capture to scrolling the wrong way. Anything less than a
        // confident reading is kept only in case nothing better turns up.
        var fallback: WorkingScroll?

        for method in methods {
            for direction in [-1, 1] {
                let label = "\(method.name) \(direction > 0 ? "+" : "-")\(step)pt"
                // A fresh, settled baseline every time. Measuring against the
                // frame the capture opened with reports movement an earlier
                // attempt caused; measuring against a page still coasting
                // reports movement nothing caused. Both make a method that does
                // nothing look like it works.
                let baseline = try await waitUntilStill(area: probe.area, options: options)

                await scroll(method, deltaY: direction * step, at: probe.centre)
                guard let frame = try await waitForSettledFrame(
                    area: probe.area, previous: baseline, options: options
                ) else {
                    trace?("\(label): no movement")
                    continue
                }

                let verdict = classify(from: baseline, to: frame, label: label)
                // Put the page back either way: on success the capture should
                // begin where the user left it, not a step further on.
                await scroll(method, deltaY: -direction * step, at: probe.centre)
                _ = try? await waitUntilStill(area: probe.area, options: options)

                guard verdict.isForward else {
                    movedBackwardsOnly = true
                    continue
                }
                let candidate = WorkingScroll(
                    method: method, direction: direction, frame: frame
                )
                if verdict.isConfident { return candidate }
                if fallback == nil { fallback = candidate }
            }
        }
        if fallback != nil { trace?("no confident direction; using the best seen") }
        return fallback
    }

    /// Whether `next` sits below `previous` in the document.
    ///
    /// Asked of the pixels rather than inferred from the sign that was sent,
    /// because getting this backwards would stitch the page in reverse and the
    /// result would look almost plausible.
    struct DirectionVerdict {
        let isForward: Bool
        /// Whether the winning reading had a real peak behind it, rather than
        /// simply outscoring an equally poor alternative.
        let isConfident: Bool
    }

    func classify(
        from previous: RasterImage, to next: RasterImage, label: String = ""
    ) -> DirectionVerdict {
        guard
            let before = GrayFrame(previous.cgImage), let after = GrayFrame(next.cgImage)
        else { return DirectionVerdict(isForward: false, isConfident: false) }

        // Exclude offsets too small to be a real scroll. Without this an
        // essentially-unmoved reading of "2px" can carry a high score and beat
        // the genuine answer, because a frame always resembles itself.
        var options = CorrelationOptions()
        options.minimumOffset = 12

        let forward = ScrollCorrelator.align(
            previous: RowDescriptors(before), next: RowDescriptors(after), options: options
        )
        let backward = ScrollCorrelator.align(
            previous: RowDescriptors(after), next: RowDescriptors(before), options: options
        )
        // Rank by confidence before score. The scores of two alignments over
        // the same pair are not comparable on their own — one of the two
        // directions is nonsense, and nonsense can score well against soft
        // content. Confidence is what says whether the curve had a real peak.
        let isForward = rank(forward) > rank(backward)
        let winner = isForward ? forward : backward
        let confident = winner?.confidence == .high
            && abs(rank(forward) - rank(backward)) > 0.5
        trace?(
            "\(label): moved — forward \(describe(forward)), backward \(describe(backward))"
                + " → \(isForward ? "down" : "up")\(confident ? "" : " (unconfident)")"
        )
        return DirectionVerdict(isForward: isForward, isConfident: confident)
    }

    /// Orders two alignments by how believable they are.
    private func rank(_ alignment: ScrollAlignment?) -> Double {
        guard let alignment else { return -1 }
        let confidence: Double = switch alignment.confidence {
        case .high: 3
        case .ambiguous: 2
        case .low: 1
        case .indeterminate: 0
        }
        return confidence + min(max(alignment.score, 0), 1)
    }

    private func describe(_ alignment: ScrollAlignment?) -> String {
        guard let alignment else { return "none" }
        return "\(alignment.offset)px/\(alignment.confidence.rawValue)/"
            + String(format: "%.3f", alignment.score)
    }

    func scroll(_ method: Method, deltaY: Int, at centre: CGPoint) async {
        switch method.delivery {
        case .toProcess(let pid):
            driver.scroll(
                deltaY: deltaY, at: centre, to: .process(pid), granularity: method.granularity
            )
        case .hardware:
            // A hardware-level event goes to whatever is under the pointer, so
            // the pointer has to be over the target. Saved once and put back
            // when the capture ends, rather than jumping per burst.
            if cursorToRestore == nil {
                cursorToRestore = CGEvent(source: nil)?.location
            }
            let moved = (CGEvent(source: nil)?.location).map {
                abs($0.x - centre.x) > 1 || abs($0.y - centre.y) > 1
            } ?? true
            CGWarpMouseCursorPosition(centre)
            // The window server does not re-evaluate what is under the pointer
            // synchronously, so an event posted immediately after a warp can be
            // delivered to whatever was under the *old* position. The gap only
            // matters when the pointer actually moved — and it moves furthest,
            // and matters most, when the target is on another display.
            if moved { try? await Task.sleep(for: .milliseconds(80)) }
            driver.scroll(
                deltaY: deltaY, at: centre, to: .systemWide, granularity: method.granularity
            )
        }
    }

    func restoreCursor() {
        guard let point = cursorToRestore else { return }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        cursorToRestore = nil
    }

    func describe(_ owner: WindowLocator.Owner?) -> String {
        guard let owner else {
            return "No window was found under the region — pick an area inside the window "
                + "you want to capture."
        }
        if movedBackwardsOnly {
            return "\(owner.name) is already at the end of its content, so there is nothing "
                + "below to capture. Scroll back to where the capture should start and "
                + "try again."
        }
        return "\(owner.name) did not respond to scrolling, in either direction, as a posted "
            + "event or as hardware input. Some windows cannot be scrolled this way; "
            + "choose \"I'll scroll it myself\" and scroll it by hand."
    }
}
