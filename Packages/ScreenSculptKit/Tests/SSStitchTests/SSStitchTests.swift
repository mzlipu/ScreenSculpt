// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Testing

@testable import SSStitch

private let frameHeight = 900

private func align(
    _ document: SyntheticDocument, from: Int, to: Int,
    options: CorrelationOptions = CorrelationOptions()
) -> ScrollAlignment? {
    let previous = RowDescriptors(document.frame(at: from, height: frameHeight))
    let next = RowDescriptors(document.frame(at: to, height: frameHeight))
    return ScrollCorrelator.align(previous: previous, next: next, options: options)
}

// MARK: - Descriptors

@Suite("Row descriptors")
struct RowDescriptorTests {

    @Test("A frame reduces to one signature per row")
    func shape() {
        let frame = SyntheticDocument.prose().frame(at: 0, height: 400)
        let descriptors = RowDescriptors(frame)
        #expect(descriptors.rowCount == 400)
        #expect(descriptors.bucketCount == 32)
        #expect(descriptors.values.count == 400 * 32)
    }

    /// Every column has to land in exactly one bucket. Dropping the remainder
    /// would quietly ignore the right-hand edge of the frame.
    @Test("Buckets cover the full width when it does not divide evenly")
    func unevenWidth() {
        var document = SyntheticDocument(width: 901, height: 4, fill: 255)
        document.fill(x: 900, y: 0, width: 1, height: 4, value: 0)
        let descriptors = RowDescriptors(document.frame(at: 0, height: 4))
        let lastBucket = descriptors.values[descriptors.bucketCount - 1]
        #expect(lastBucket < 255, "the final column never reached a bucket")
    }

    @Test("A wider bucket count than the image is clamped")
    func clampsBuckets() {
        let frame = SyntheticDocument(width: 8, height: 4, fill: 128).frame(at: 0, height: 4)
        #expect(RowDescriptors(frame, bucketCount: 64).bucketCount == 8)
    }
}

// MARK: - Alignment

@Suite("Scroll alignment")
struct AlignmentTests {

    @Test("A known scroll distance is recovered exactly", arguments: [40, 137, 300, 640])
    func recoversOffset(distance: Int) throws {
        let result = try #require(align(.prose(), from: 1000, to: 1000 + distance))
        #expect(result.offset == distance)
        #expect(result.confidence == .high, "got \(result.confidence) at \(result.score)")
    }

    @Test("Confidence is high and the margin is real on ordinary content")
    func confidentOnProse() throws {
        let result = try #require(align(.prose(), from: 500, to: 740))
        #expect(result.score > 0.9)
        #expect(result.margin > 0.05)
        #expect(result.contenders == 0)
    }

    /// The failure the whole confidence apparatus exists for. A list of equal
    /// rows matches just as well one row down as ten, and a stitcher that picks
    /// one anyway drops or repeats content with no visible seam.
    @Test("Repeating rows are reported as ambiguous, not guessed at")
    func periodicContentIsAmbiguous() throws {
        let result = try #require(align(.periodic(period: 40), from: 800, to: 1000))
        #expect(result.confidence == .ambiguous)
        #expect(result.contenders > 0, "a comb of equal peaks should have been seen")
    }

    @Test("A blank region reports indeterminate rather than an offset")
    func blankIsIndeterminate() throws {
        let result = try #require(align(.blank(), from: 100, to: 400))
        #expect(result.confidence == .indeterminate)
    }

    @Test("Searching is bounded by the requested maximum")
    func respectsMaximum() throws {
        var options = CorrelationOptions()
        options.maximumOffset = 100
        let result = try #require(align(.prose(), from: 0, to: 400, options: options))
        #expect(result.offset <= 100)
        // The true answer is outside the window, so it must not claim confidence.
        #expect(result.confidence != .high)
    }

    @Test("Frames with mismatched bucket counts are refused")
    func mismatchedBuckets() {
        let document = SyntheticDocument.prose()
        let previous = RowDescriptors(document.frame(at: 0, height: 200), bucketCount: 16)
        let next = RowDescriptors(document.frame(at: 100, height: 200), bucketCount: 32)
        #expect(ScrollCorrelator.align(previous: previous, next: next) == nil)
    }
}

// MARK: - Sticky bands

@Suite("Sticky bands")
struct StickyBandTests {

    private func stickyFrames(header: Int, footer: Int = 0) -> [GrayFrame] {
        let document = SyntheticDocument.prose()
        return stride(from: 1000, to: 1000 + 4 * 250, by: 250).map { offset in
            var frame = document.frame(at: offset, height: frameHeight)
            if header > 0 { frame = frame.withStickyBand(rows: header, atTop: true) }
            if footer > 0 { frame = frame.withStickyBand(rows: footer, atTop: false, seed: 5) }
            return frame
        }
    }

    /// The band's exact edge is not discoverable, and the contract says so: a
    /// blank gutter sitting against the header is unchanged between frames for
    /// the same reason the header is, so it belongs to the largest static run.
    /// Over-reading is the safe direction — `StitchCanvas` pastes each frame's
    /// whole content region, so rows one frame trims are written by the next.
    @Test("A fixed header is measured")
    func findsHeader() {
        let bands = StickyBandDetector.detect(in: stickyFrames(header: 64))
        #expect(bands.top >= 64, "missed part of the header: \(bands.top)")
        #expect(bands.top < 64 + 28, "ran past the first inked line: \(bands.top)")
        #expect(bands.bottom == 0)
    }

    @Test("A fixed footer is measured")
    func findsFooter() {
        let bands = StickyBandDetector.detect(in: stickyFrames(header: 0, footer: 48))
        #expect(bands.bottom >= 48, "missed part of the footer: \(bands.bottom)")
        #expect(bands.bottom < 48 + 28, "ran past the first inked line: \(bands.bottom)")
    }

    @Test("Scrolling content has no sticky bands")
    func noneOnPlainScroll() {
        let document = SyntheticDocument.prose()
        let frames = stride(from: 1000, to: 2000, by: 250).map {
            document.frame(at: $0, height: frameHeight)
        }
        #expect(StickyBandDetector.detect(in: frames) == .none)
    }

    /// Blank margin is unchanged between frames but is not a header. Treating
    /// it as one would trim real content off every frame after the first.
    @Test("Blank space is not mistaken for a header")
    func blankIsNotSticky() {
        let document = SyntheticDocument.blank()
        let frames = stride(from: 0, to: 1000, by: 250).map {
            document.frame(at: $0, height: frameHeight)
        }
        #expect(StickyBandDetector.detect(in: frames) == .none)
    }

    @Test("A band is capped so a motionless pair does not read as all sticky")
    func capsAtFraction() {
        let document = SyntheticDocument.prose()
        let still = document.frame(at: 500, height: frameHeight)
        let bands = StickyBandDetector.detect(in: [still, still, still])
        #expect(bands.top <= Int(Double(frameHeight) * 0.4))
    }

    @Test("One frame pair is not enough to confirm a band")
    func requiresConfirmation() {
        let frames = Array(stickyFrames(header: 64).prefix(2))
        var options = StickyBandOptions()
        options.requiredPairs = 3
        #expect(StickyBandDetector.detect(in: frames, options: options) == .none)
    }

    /// Without trimming, the unmoving header correlates perfectly at every
    /// offset and flattens the score curve that confidence is read from.
    @Test("Trimming the header restores a confident alignment")
    func headerDefeatsUntrimmedAlignment() throws {
        let document = SyntheticDocument.prose()
        let header = 120
        let previous = document.frame(at: 1000, height: frameHeight)
            .withStickyBand(rows: header, atTop: true)
        let next = document.frame(at: 1240, height: frameHeight)
            .withStickyBand(rows: header, atTop: true)

        var trimmed = CorrelationOptions()
        trimmed.sampleOrigin = header
        let result = try #require(
            ScrollCorrelator.align(
                previous: RowDescriptors(previous), next: RowDescriptors(next),
                options: trimmed
            )
        )
        #expect(result.offset == 240)
        #expect(result.confidence == .high)
    }
}

// MARK: - Verification

@Suite("Overlap verification")
struct VerifierTests {

    @Test("The correct offset passes")
    func correctOffsetPasses() {
        let document = SyntheticDocument.prose()
        let check = StitchVerifier.check(
            previous: document.frame(at: 1000, height: frameHeight),
            next: document.frame(at: 1240, height: frameHeight),
            offset: 240
        )
        #expect(check.passed)
        #expect(check.error < 1)
    }

    /// The property that matters: a plausible but wrong offset must be caught
    /// here, because nothing downstream can tell.
    @Test("A wrong offset fails", arguments: [230, 241, 300])
    func wrongOffsetFails(offset: Int) {
        let document = SyntheticDocument.prose()
        let check = StitchVerifier.check(
            previous: document.frame(at: 1000, height: frameHeight),
            next: document.frame(at: 1240, height: frameHeight),
            offset: offset
        )
        #expect(!check.passed, "offset \(offset) slipped through at error \(check.error)")
    }

    @Test("A nonsensical offset is rejected rather than scored")
    func rejectsImpossibleOffset() {
        let document = SyntheticDocument.prose()
        let frame = document.frame(at: 0, height: frameHeight)
        #expect(!StitchVerifier.check(previous: frame, next: frame, offset: 0).passed)
        #expect(!StitchVerifier.check(previous: frame, next: frame, offset: 5000).passed)
    }
}
