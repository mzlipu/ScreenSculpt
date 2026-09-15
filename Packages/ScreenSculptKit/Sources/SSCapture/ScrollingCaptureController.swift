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
    case stalled(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "Scrolling capture needs Accessibility access so ScreenSculpt can scroll the window "
                + "for you."
        case .regionTooSmall:
            "Choose a taller region — there is not enough overlap between frames to line them up."
        case .noContentCaptured:
            "Nothing was captured."
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
        public init() {}
    }

    public struct Progress: Sendable {
        public let frames: Int
        public let rows: Int
    }

    private let captureService: any CaptureService
    private let driver = ScrollDriver()
    /// Retained after `capture` so the assembled pixels can still be read.
    /// The canvas is a file-backed window, not a bitmap, so this holds a
    /// mapping and a descriptor rather than the image.
    private var session: StitchSession?

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

        let centre = CGPoint(
            x: area.midX.value, y: area.midY.value
        )
        let target: ScrollDriver.Target = WindowLocator.processOwningWindow(at: centre)
            .map { .process($0) } ?? .systemWide

        let first = try await captureService.capture(CaptureRequest(mode: .area(area)))
        let scale = first.provenance.pixelScale

        // Scroll a fixed fraction of the band so consecutive frames always
        // overlap. Commanded in points; the stitcher measures in pixels.
        let stepPoints = Int(area.height.value * (1 - options.overlapFraction))
        var configuration = StitchConfiguration()
        configuration.expectedStep = Int(scale.pixels(LogicalPt(Double(stepPoints))).value)

        let session = try StitchSession(
            firstFrame: first.image.cgImage, pixelScale: scale, configuration: configuration
        )
        self.session = session

        // Which sign moves further down the document is not knowable up front —
        // it depends on the application, and synthesised events do not go
        // through the system's natural-scrolling flip. So try one direction and
        // reverse if the page did not move.
        var direction = -1
        var reversed = false
        var settled = first.image

        for index in 1...options.maximumFrames {
            driver.scroll(deltaY: direction * stepPoints, at: centre, to: target)

            guard let frame = try await waitForSettledFrame(
                area: area, previous: settled, options: options
            ) else {
                if index == 1, !reversed {
                    reversed = true
                    direction = 1
                    continue
                }
                break       // the page stopped moving: the end of the content
            }

            switch session.add(frame.cgImage) {
            case .buffered, .appended:
                settled = frame
                onProgress(Progress(frames: index, rows: session.canvas.filledRows))
            case .reachedEnd:
                if index == 1, !reversed {
                    reversed = true
                    direction = 1
                    continue
                }
                return session.finish()
            case .unreliable(let reason):
                session.note("Stopped early: \(reason)")
                let partial = session.finish()
                guard partial.frameCount > 1 else { throw ScrollingCaptureError.stalled(reason) }
                return partial
            }
        }

        let result = session.finish()
        guard !result.isEmpty else { throw ScrollingCaptureError.noContentCaptured }
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

    /// Capture until the page stops changing, then return that frame.
    ///
    /// Returns nil when the page never differed from the previous frame, which
    /// is how reaching the bottom announces itself.
    private func waitForSettledFrame(
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
