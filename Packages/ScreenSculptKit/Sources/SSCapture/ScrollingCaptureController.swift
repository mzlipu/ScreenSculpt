// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import SSPlatform
import SSStitch

public enum ScrollingCaptureError: Error, LocalizedError {
    case accessibilityRequired
    case regionTooSmall
    case noContentCaptured
    case pageDidNotScroll(String)
    case stalled(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "Scrolling capture needs Accessibility access so Screen Sculpt can scroll the window "
                + "for you."
        case .regionTooSmall:
            "Choose a taller region — there is not enough overlap between frames to line them up."
        case .noContentCaptured:
            "Nothing was captured."
        case .pageDidNotScroll(let detail):
            "The page did not scroll. \(detail)"
        case .stalled(let detail):
            detail
        }
    }
}

/// Runs a scrolling capture: scroll a little, wait for the page to settle,
/// capture, repeat.
///
/// Stops the moment a frame cannot be placed. A scroll capture that quietly
/// drops a paragraph looks exactly like a correct one, so anything short of
/// certainty is reported rather than absorbed.
@MainActor
public final class ScrollingCaptureController {

    public struct Options: Sendable {
        public var maximumFrames = 120
        /// Fraction of the band left overlapping between consecutive frames.
        /// This overlap is the only material the correlator has to work with.
        public var overlapFraction = 0.3
        /// How long to wait for a page to stop moving after a scroll.
        public var settleTimeout = Duration.milliseconds(1500)
        public var settleInterval = Duration.milliseconds(50)
        /// Consecutive identical captures required before a frame is accepted.
        public var settleConfirmations = 2
        /// Manual mode: how often to look at the page.
        public var manualPollInterval = Duration.milliseconds(120)
        /// Manual mode: how long the page may sit still, once scrolling has
        /// started, before the capture is considered finished.
        public var manualIdleTimeout = Duration.seconds(4)
        /// Manual mode: how long to wait for scrolling to begin at all.
        ///
        /// Much longer than the idle timeout, because the user has to reach the
        /// window and start scrolling. Short of this the capture would end
        /// before they had begun.
        public var manualStartTimeout = Duration.seconds(30)
        public init() {}
    }

    public struct Progress: Sendable {
        public let frames: Int
        public let rows: Int
    }

    let captureService: any CaptureService
    let driver = ScrollDriver()
    /// Retained after `capture` so the assembled pixels can still be read.
    /// The canvas is a file-backed window, not a bitmap, so this holds a
    /// mapping and a descriptor rather than the image.
    private var session: StitchSession?
    /// Where the pointer was before a hardware-level scroll moved it.
    var cursorToRestore: CGPoint?
    /// Set when probing found the page moves, but only towards its start.
    var movedBackwardsOnly = false

    /// Receives a line per calibration attempt.
    ///
    /// Which way a window scrolls, and whether it listens at all, is a property
    /// of that window — so when a capture fails the useful question is what was
    /// tried and what each attempt saw. Nothing else can reconstruct that.
    public var trace: (@MainActor (String) -> Void)?

    public init(captureService: any CaptureService) {
        self.captureService = captureService
    }

    /// Capture a scrolling region.
    ///
    /// - Parameter area: the region to capture, in CG global coordinates.
    public func capture(
        area: ScreenRect,
        options: Options = Options(),
        onProgress: @MainActor (Progress) -> Void = { _ in }
    ) async throws -> StitchResult {
        guard AXIsProcessTrusted() else { throw ScrollingCaptureError.accessibilityRequired }
        guard area.height.value >= 200 else { throw ScrollingCaptureError.regionTooSmall }
        defer { restoreCursor() }

        let centre = CGPoint(x: area.midX.value, y: area.midY.value)
        let owner = WindowLocator.windowOwner(at: centre)

        let scale = try await captureService
            .capture(CaptureRequest(mode: .area(area))).provenance.pixelScale
        // Let anything already in motion finish before measuring. Otherwise the
        // first calibration attempt is credited with movement it did not cause.
        let opening = try await waitUntilStill(area: area, options: options)

        // Scroll a fixed fraction of the band so consecutive frames always
        // overlap. Commanded in points; the stitcher measures in pixels.
        let stepPoints = Int(area.height.value * (1 - options.overlapFraction))

        // Establish how this window scrolls before the first frame is kept.
        // Calibration moves the page and puts it back, so the frame the capture
        // opens with has to be taken afterwards — one taken before would be a
        // view of a position the page is no longer at.
        let probe = Probe(
            area: area, centre: centre, owner: owner,
            step: stepPoints, first: opening
        )
        guard let working = try await findWorkingScroll(probe, options: options) else {
            throw ScrollingCaptureError.pageDidNotScroll(describe(owner))
        }

        let first = try await waitUntilStill(area: area, options: options)
        var configuration = StitchConfiguration()
        configuration.expectedStep = Int(scale.pixels(LogicalPt(Double(stepPoints))).value)
        let session = try StitchSession(
            firstFrame: first.cgImage, pixelScale: scale, configuration: configuration
        )
        self.session = session
        var settled = first

        var reachedEnd = false
        for index in 1...max(2, options.maximumFrames) {
            await scroll(working.method, deltaY: working.direction * stepPoints, at: centre)

            guard let frame = try await waitForSettledFrame(
                area: area, previous: settled, options: options
            ) else { break }       // the page stopped moving: the end of the content

            switch session.add(frame.cgImage) {
            case .buffered, .appended:
                settled = frame
                onProgress(Progress(frames: index + 1, rows: session.canvas.filledRows))
            case .reachedEnd:
                // Leaves by the shared exit below rather than returning here.
                // Returning directly skipped the one-frame check, so a capture
                // that reached the end on its first step handed back a single
                // screenful as though it had worked.
                reachedEnd = true
            case .unreliable(let reason):
                session.note("Stopped early: \(reason)")
                let partial = session.finish()
                guard partial.frameCount > 1 else { throw ScrollingCaptureError.stalled(reason) }
                return partial
            }
            if reachedEnd { break }
        }

        let result = session.finish()
        guard !result.isEmpty else { throw ScrollingCaptureError.noContentCaptured }
        guard result.frameCount > 1 else {
            // One frame is an ordinary screenshot. Returning it as though the
            // capture had worked is the worst outcome available — it looks like
            // success and silently is not.
            throw ScrollingCaptureError.pageDidNotScroll(
                "Only the first screenful could be captured before the page stopped moving."
            )
        }
        return result
    }

    /// Capture a region the user scrolls themselves.
    ///
    /// Needs no Accessibility grant, which is the whole point of having it:
    /// the automatic mode has to be allowed to send input, and a fair number of
    /// people will decline that — reasonably, for a screenshot tool. It is also
    /// the fallback when an application ignores synthesised scroll entirely,
    /// and it works horizontally and in any application, because the app is
    /// only watching.
    ///
    /// The settle detector and the stitcher are the same ones the automatic
    /// mode uses; only the source of the movement differs.
    public func captureManually(
        area: ScreenRect,
        options: Options = Options(),
        shouldStop: @MainActor () -> Bool = { false },
        onProgress: @MainActor (Progress) -> Void = { _ in }
    ) async throws -> StitchResult {
        guard area.height.value >= 200 else { throw ScrollingCaptureError.regionTooSmall }

        let first = try await captureService.capture(CaptureRequest(mode: .area(area)))
        guard var committed = GrayFrame(first.image.cgImage) else {
            throw ScrollingCaptureError.noContentCaptured
        }
        let session = try StitchSession(
            firstFrame: first.image.cgImage, pixelScale: first.provenance.pixelScale
        )
        self.session = session

        var previousPoll: GrayFrame?
        var idle = Duration.zero
        var frames = 1

        while !shouldStop(), frames < options.maximumFrames {
            try await Task.sleep(for: options.manualPollInterval)
            let shot = try await captureService.capture(CaptureRequest(mode: .area(area)))
            guard let gray = GrayFrame(shot.image.cgImage) else { continue }

            if gray.matches(committed) {
                // Back where the last accepted frame was: nothing new yet.
                idle += options.manualPollInterval
                // Waiting to start is not the same as having finished, so the
                // two get different allowances. Sharing one would either end
                // the capture before the user reached the window, or leave a
                // page that never scrolls polling until the frame ceiling.
                let allowance = frames > 1
                    ? options.manualIdleTimeout
                    : options.manualStartTimeout
                if idle >= allowance { break }
                previousPoll = gray
                continue
            }
            idle = .zero

            // Only commit once the page has stopped, or a frame caught
            // mid-scroll would be stitched and every later offset measured
            // from a blur.
            guard let previous = previousPoll, previous.matches(gray) else {
                previousPoll = gray
                continue
            }

            switch session.add(shot.image.cgImage) {
            case .buffered, .appended:
                committed = gray
                previousPoll = gray
                frames += 1
                onProgress(Progress(frames: frames, rows: session.canvas.filledRows))
            case .reachedEnd:
                previousPoll = gray
            case .unreliable(let reason):
                session.note(
                    "Stopped early: \(reason) Scrolling in smaller steps keeps enough "
                        + "overlap between frames."
                )
                let partial = session.finish()
                guard partial.frameCount > 1 else {
                    throw ScrollingCaptureError.stalled(
                        reason + " Try scrolling more slowly, a little at a time."
                    )
                }
                return partial
            }
        }

        let result = session.finish()
        guard result.frameCount > 1 else {
            throw ScrollingCaptureError.stalled(
                "No scrolling was detected. Scroll the window while the capture is running."
            )
        }
        return result
    }

    /// The finished stitch, when it is short enough to hold as one image.
    ///
    /// Nil for a genuinely long page: past 65,535 rows there is no single
    /// `CGImage` to make, and `writePNG` is the way out.
    public func finishedImage() -> RasterImage? { session?.makeImage() }

    /// Stream the finished stitch to a file, at any height.
    public func writePNG(to url: URL) throws {
        guard let session else { throw ScrollingCaptureError.noContentCaptured }
        try session.writePNG(to: url)
    }

    /// Capture until the page is at rest, and return that frame.
    ///
    /// Distinct from `waitForSettledFrame`, which asks whether the page has
    /// moved *somewhere new*. This asks only whether it has stopped, and the
    /// difference matters before a measurement: a page still coasting from an
    /// earlier scroll keeps changing on its own, so an attempt that did nothing
    /// registers as having worked.
    func waitUntilStill(area: ScreenRect, options: Options) async throws -> RasterImage {
        var last: GrayFrame?
        var lastImage = try await captureService.capture(CaptureRequest(mode: .area(area))).image
        let deadline = ContinuousClock.now + options.settleTimeout

        while ContinuousClock.now < deadline {
            try await Task.sleep(for: options.settleInterval)
            let shot = try await captureService.capture(CaptureRequest(mode: .area(area)))
            lastImage = shot.image
            guard let gray = GrayFrame(shot.image.cgImage) else { continue }
            if let last, last.matches(gray) { return shot.image }
            last = gray
        }
        return lastImage
    }

    /// Capture until the page stops changing, then return that frame.
    ///
    /// Returns nil when the page never differed from the previous frame, which
    /// is how reaching the bottom announces itself.
    func waitForSettledFrame(
        area: ScreenRect, previous: RasterImage, options: Options
    ) async throws -> RasterImage? {
        let deadline = ContinuousClock.now + options.settleTimeout
        var lastGray: GrayFrame?
        var lastImage: RasterImage?
        var stableCount = 0

        while ContinuousClock.now < deadline {
            try await Task.sleep(for: options.settleInterval)
            let shot = try await captureService.capture(CaptureRequest(mode: .area(area)))
            guard let gray = GrayFrame(shot.image.cgImage) else { continue }

            if let lastGray, framesMatch(lastGray, gray) {
                stableCount += 1
                if stableCount >= options.settleConfirmations {
                    guard let previousGray = GrayFrame(previous.cgImage),
                          !framesMatch(previousGray, gray)
                    else { return nil }
                    return shot.image
                }
            } else {
                stableCount = 0
            }
            lastGray = gray
            lastImage = shot.image
        }

        // Timed out while still moving — an animation, a video, a slow page.
        // The last frame is still usable if it differs from where we started.
        guard let lastImage, let lastGray, let previousGray = GrayFrame(previous.cgImage),
              !framesMatch(previousGray, lastGray)
        else { return nil }
        return lastImage
    }

    /// Cheap whole-frame comparison over a sample of rows.
    private func framesMatch(_ lhs: GrayFrame, _ rhs: GrayFrame) -> Bool {
        lhs.matches(rhs)
    }
}
