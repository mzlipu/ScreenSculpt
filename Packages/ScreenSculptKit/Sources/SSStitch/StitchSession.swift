// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging

public struct StitchConfiguration: Sendable {
    /// Ceiling on the assembled height. Sparse, so a generous value is cheap.
    public var maximumRows = 200_000
    /// Frames buffered before sticky bands are decided. One pair cannot tell a
    /// fixed header from content that happened not to change.
    public var stickyDetectionFrames = 3
    /// Mean absolute luminance error still counted as a match.
    public var verifyTolerance: Double = 6
    /// Movement below this is treated as having reached the end.
    public var minimumStep = 4
    /// Rows either side of a candidate searched at full resolution when the
    /// descriptor answer does not verify.
    public var refinementRadius = 10
    /// How far the page was asked to scroll, when something commanded it.
    ///
    /// Only used to break ties, and that is the one case it decides: content
    /// that repeats exactly matches at every multiple of its period, so several
    /// offsets verify perfectly and the pixels cannot say which is right. Left
    /// nil, the smallest wins and a list of identical rows stitches short.
    public var expectedStep: Int?
    public init() {}
}

public enum StitchFrameOutcome: Sendable, Equatable {
    /// Held back until sticky bands are known. Nothing is wrong; keep going.
    case buffered
    /// Accepted, having moved this many rows since the previous frame.
    case appended(offset: Int)
    /// The page did not move. The end of the content, or a scroll that failed.
    case reachedEnd
    /// Refused. Stitching this frame would have produced a plausible-looking
    /// image with content missing or repeated.
    case unreliable(String)
}

public struct StitchResult: Sendable {
    public let rows: Int
    public let width: Int
    public let frameCount: Int
    public let stickyBands: StickyBands
    public let warnings: [String]
    /// Every accepted movement, in order. A bad stitch is usually obvious here
    /// as one offset out of step with its neighbours.
    public let offsets: [Int]

    public var isEmpty: Bool { rows == 0 }
}

/// Assembles a scroll into one image, one frame at a time.
///
/// Every accepted offset is confirmed against full-resolution pixels before the
/// frame is committed, whatever the correlator's confidence. A wrong offset does
/// not look wrong in the output — it looks like a page that is simply missing a
/// paragraph — so there is no safe point at which to trust an unverified
/// answer. When nothing verifies, the frame is refused and the reason is
/// carried out to the user rather than papered over.
public final class StitchSession {

    public let canvas: StitchCanvas
    public private(set) var stickyBands: StickyBands = .none
    public private(set) var frameCount = 0
    public private(set) var warnings: [String] = []
    /// Where the most recent frame's top edge sits in the assembled image.
    public private(set) var documentOffset = 0
    /// Every accepted movement, in order.
    public private(set) var offsets: [Int] = []

    private let configuration: StitchConfiguration
    private let pixelScale: PixelScale
    private let width: Int
    private let frameHeight: Int

    private var pending: [(image: CGImage, gray: GrayFrame)] = []
    private var settled = false
    private var previousGray: GrayFrame?
    private var previousDescriptors: RowDescriptors?

    public init(
        firstFrame: CGImage,
        pixelScale: PixelScale,
        configuration: StitchConfiguration = StitchConfiguration()
    ) throws {
        guard let gray = GrayFrame(firstFrame) else { throw StitchCanvasError.invalidSize }
        self.configuration = configuration
        self.pixelScale = pixelScale
        self.width = firstFrame.width
        self.frameHeight = firstFrame.height
        self.canvas = try StitchCanvas(
            width: firstFrame.width, capacity: configuration.maximumRows
        )
        pending.append((firstFrame, gray))
    }

    // MARK: - Adding frames

    @discardableResult
    public func add(_ frame: CGImage) -> StitchFrameOutcome {
        guard frame.width == width, frame.height == frameHeight else {
            return .unreliable("The window changed size during the capture.")
        }
        guard let gray = GrayFrame(frame) else {
            return .unreliable("A frame could not be read.")
        }

        if !settled {
            pending.append((frame, gray))
            if pending.count >= max(2, configuration.stickyDetectionFrames) {
                return flushPending()
            }
            return .buffered
        }

        return commit(image: frame, gray: gray)
    }

    /// Decide the sticky bands, then lay down the buffered frames.
    ///
    /// Nothing is pasted before this point. A frame written with the wrong
    /// bands would stamp a copy of the header over content that no later frame
    /// reaches, and the overwrite-on-overlap rule cannot repair that.
    private func flushPending() -> StitchFrameOutcome {
        stickyBands = StickyBandDetector.detect(in: pending.map(\.gray))
        settled = true

        let first = pending.removeFirst()
        // The first frame keeps its header: at the top of the page that band is
        // the page, not a repeat. Its footer is overwritten by whatever follows.
        canvas.paste(first.image, atRow: 0, sticky: StickyBands(top: 0, bottom: 0))
        previousGray = first.gray
        previousDescriptors = RowDescriptors(first.gray)
        frameCount = 1

        var outcome = StitchFrameOutcome.buffered
        let buffered = pending
        pending.removeAll()
        for frame in buffered {
            outcome = commit(image: frame.image, gray: frame.gray)
            if case .appended = outcome { continue }
            break
        }
        return outcome
    }

    private func commit(image: CGImage, gray: GrayFrame) -> StitchFrameOutcome {
        guard let previousGray, let previousDescriptors else {
            return .unreliable("The capture has no starting frame.")
        }

        let descriptors = RowDescriptors(gray)
        var options = CorrelationOptions()
        options.sampleOrigin = stickyBands.top
        options.minimumOffset = configuration.minimumStep
        options.maximumOffset = frameHeight - stickyBands.top - stickyBands.bottom

        let alignment = ScrollCorrelator.align(
            previous: previousDescriptors, next: descriptors, options: options
        )

        if isStationary(previousGray, gray) { return .reachedEnd }

        guard let resolved = resolve(alignment, previous: previousGray, next: gray) else {
            let detail = alignment.map {
                "confidence \($0.confidence.rawValue), best \(String(format: "%.2f", $0.score))"
            } ?? "no usable signal"
            return .unreliable(
                "Could not line this frame up with the previous one (\(detail))."
            )
        }

        if alignment?.confidence == .ambiguous {
            warnings.append(
                "Repeating content near row \(documentOffset); the offset was confirmed "
                    + "against full-resolution pixels."
            )
        }

        documentOffset += resolved
        offsets.append(resolved)
        canvas.paste(image, atRow: documentOffset, sticky: stickyBands)
        self.previousGray = gray
        self.previousDescriptors = descriptors
        frameCount += 1
        return .appended(offset: resolved)
    }

    // MARK: - The confidence ladder

    /// Confirm a candidate offset, or find one that does confirm.
    ///
    /// The correlator works on 32 averages per row; two different rows can share
    /// that profile. So its answer is a proposal, checked here at full
    /// resolution, and a neighbourhood is swept when the proposal fails — which
    /// is what recovers the common case of a correlator landing a pixel or two
    /// out on soft content.
    private func resolve(
        _ alignment: ScrollAlignment?, previous: GrayFrame, next: GrayFrame
    ) -> Int? {
        var verified: [(offset: Int, error: Double)] = []

        func consider(_ offset: Int) {
            guard offset >= configuration.minimumStep, offset < frameHeight else { return }
            guard !verified.contains(where: { $0.offset == offset }) else { return }
            let check = StitchVerifier.check(
                previous: previous, next: next, offset: offset,
                sticky: stickyBands, tolerance: configuration.verifyTolerance
            )
            if check.passed { verified.append((offset, check.error)) }
        }

        let expected = expectedStep
        if let candidate = alignment?.offset { consider(candidate) }
        if let expected { consider(expected) }

        if verified.isEmpty, let candidate = alignment?.offset {
            // The correlator can land a pixel or two out on soft edges; sweep
            // its neighbourhood at full resolution before giving up.
            for delta in 1...configuration.refinementRadius {
                consider(candidate - delta)
                consider(candidate + delta)
            }
        }
        guard !verified.isEmpty else { return nil }

        // Errors within a whisker of each other mean the pixels genuinely
        // cannot choose — repeating content. Then, and only then, the expected
        // step decides; otherwise the lowest error wins outright.
        let lowest = verified.map(\.error).min()!
        let tied = verified.filter { $0.error <= lowest + 0.25 }
        guard tied.count > 1, let expected else {
            return verified.min { $0.error < $1.error }!.offset
        }
        return tied.min { abs($0.offset - expected) < abs($1.offset - expected) }!.offset
    }

    /// What the next step is likely to be: what was commanded, or failing that
    /// the median of what has actually been measured.
    private var expectedStep: Int? {
        if let configured = configuration.expectedStep { return configured }
        guard !offsets.isEmpty else { return nil }
        return offsets.sorted()[offsets.count / 2]
    }

    /// Whether the page stopped moving, which is how the end announces itself.
    private func isStationary(_ previous: GrayFrame, _ next: GrayFrame) -> Bool {
        let rows = min(previous.height, next.height)
        let from = stickyBands.top
        let to = rows - stickyBands.bottom
        guard to - from > 8 else { return false }

        var total = 0.0
        var counted = 0
        var row = from
        let step = max(1, (to - from) / 64)
        while row < to {
            total += previous.rowDifference(row, against: next, row: row)
            counted += 1
            row += step
        }
        return counted > 0 && total / Double(counted) <= 1.0
    }

    /// Record something the user should be told about the result.
    public func note(_ warning: String) { warnings.append(warning) }

    // MARK: - Finishing

    /// Commit anything still buffered and report the assembled size.
    @discardableResult
    public func finish() -> StitchResult {
        if !settled, !pending.isEmpty { _ = flushPending() }
        return StitchResult(
            rows: canvas.filledRows, width: width, frameCount: frameCount,
            stickyBands: stickyBands, warnings: warnings, offsets: offsets
        )
    }

    /// The finished stitch, when it is short enough to hold as one image.
    public func makeImage() -> RasterImage? { canvas.makeImage(pixelScale: pixelScale) }

    public func writePNG(to url: URL) throws { try canvas.writePNG(to: url) }
}
