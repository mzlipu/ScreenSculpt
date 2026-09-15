// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import Testing

@testable import SSStitch

private let viewport = 800

/// Feed a document through a session at a fixed scroll step.
private func run(
    _ document: SyntheticDocument,
    step: Int,
    frames: Int,
    decorate: ((CGImage, Int) -> CGImage)? = nil,
    configuration: StitchConfiguration = StitchConfiguration()
) throws -> (session: StitchSession, outcomes: [StitchFrameOutcome]) {
    func image(_ index: Int) -> CGImage {
        let raw = document.cgImage(at: index * step, height: viewport)
        return decorate?(raw, index) ?? raw
    }

    let session = try StitchSession(
        firstFrame: image(0), pixelScale: .x1, configuration: configuration
    )
    var outcomes: [StitchFrameOutcome] = []
    for index in 1..<frames { outcomes.append(session.add(image(index))) }
    return (session, outcomes)
}

/// Luminance of one canvas pixel.
private func luminance(_ session: StitchSession, x: Int, y: Int) -> Int {
    session.canvas.withRow(y) { Int($0[x * 4]) }
}

@Suite("Stitch session")
struct StitchSessionTests {

    @Test("A clean scroll assembles to the right height")
    func assemblesHeight() throws {
        let step = 300
        let frames = 8
        let (session, outcomes) = try run(.prose(), step: step, frames: frames)
        let result = session.finish()

        for outcome in outcomes where outcome != .buffered {
            #expect(outcome == .appended(offset: step), "got \(outcome)")
        }
        #expect(result.rows == (frames - 1) * step + viewport)
        #expect(result.frameCount == frames)
        #expect(result.warnings.isEmpty)
    }

    /// Height alone can be right while the content is scrambled, so this checks
    /// the pixels actually landed where the document says they should.
    @Test("Assembled pixels match the source document")
    func pixelsMatchSource() throws {
        let document = SyntheticDocument.prose()
        let (session, _) = try run(document, step: 260, frames: 10)
        let result = session.finish()

        for row in stride(from: 5, to: result.rows - 5, by: 137) {
            for x in [10, 200, 640] {
                let expected = Int(document.pixels[row * document.width + x])
                let actual = luminance(session, x: x, y: row)
                #expect(abs(actual - expected) <= 2, "row \(row), x \(x)")
            }
        }
    }

    @Test("Varying scroll steps are each measured")
    func variableSteps() throws {
        let document = SyntheticDocument.prose()
        let steps = [180, 340, 95, 420, 260]
        var offset = 0

        let session = try StitchSession(
            firstFrame: document.cgImage(at: 0, height: viewport), pixelScale: .x1
        )
        for step in steps {
            offset += step
            session.add(document.cgImage(at: offset, height: viewport))
        }
        let result = session.finish()

        #expect(result.offsets == steps, "measured \(result.offsets)")
        #expect(session.canvas.filledRows == offset + viewport)
    }

    @Test("A page that stops scrolling reports the end")
    func detectsEnd() throws {
        let document = SyntheticDocument.prose()
        let session = try StitchSession(
            firstFrame: document.cgImage(at: 0, height: viewport), pixelScale: .x1
        )
        for index in 1...3 {
            session.add(document.cgImage(at: index * 300, height: viewport))
        }
        // The same view again: the page is already at the bottom.
        let outcome = session.add(document.cgImage(at: 900, height: viewport))
        #expect(outcome == .reachedEnd)
    }

    @Test("A fixed header and footer are found and excluded")
    func handlesStickyChrome() throws {
        let header = 70
        let footer = 40
        let step = 300
        let frames = 7
        let (session, outcomes) = try run(.prose(), step: step, frames: frames) { image, _ in
            var frame = GrayFrame(image)!
            frame = frame.withStickyBand(rows: header, atTop: true)
            frame = frame.withStickyBand(rows: footer, atTop: false, seed: 3)
            return frame.asImage()
        }
        let result = session.finish()

        #expect(result.stickyBands.top >= header)
        #expect(result.stickyBands.bottom >= footer)
        for outcome in outcomes where outcome != .buffered {
            #expect(outcome == .appended(offset: step), "got \(outcome)")
        }
        // Ground truth: the last frame's content ends before its footer.
        #expect(result.rows == (frames - 1) * step + viewport - result.stickyBands.bottom)
    }

    /// The property that matters most. A frame that cannot be placed must be
    /// refused: an image quietly missing a paragraph is worse than a capture
    /// that says it failed.
    @Test("An unplaceable frame is refused rather than guessed")
    func refusesUnplaceableFrame() throws {
        let document = SyntheticDocument.prose()
        let other = SyntheticDocument.prose(seed: 991)
        let session = try StitchSession(
            firstFrame: document.cgImage(at: 0, height: viewport), pixelScale: .x1
        )
        session.add(document.cgImage(at: 300, height: viewport))
        session.add(document.cgImage(at: 600, height: viewport))

        // An unrelated page, as though the user switched windows mid-capture.
        let outcome = session.add(other.cgImage(at: 4000, height: viewport))
        guard case .unreliable(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("line this frame up"))
    }

    /// Exactly repeating content is not merely hard, it is undecidable from the
    /// pixels: a page whose rows repeat every 40 lines matches equally well at
    /// 20 rows and at 260, and both are perfect matches. Nothing in the image
    /// can break that tie.
    ///
    /// So the correlator must say so rather than pick, and it does — which is
    /// what the warning below records.
    @Test("Repeating content is reported, not silently resolved")
    func periodicContentWarns() throws {
        let (session, _) = try run(.periodic(period: 40), step: 260, frames: 6)
        let result = session.finish()
        #expect(
            !result.warnings.isEmpty,
            "a page of identical rows stitched without comment"
        )
    }

    /// The tie is broken by knowing what was asked for. A driver that commanded
    /// the scroll always does, which is why this is the case that matters in
    /// practice.
    @Test("A commanded step resolves repeating content exactly")
    func periodicContentWithExpectedStep() throws {
        let step = 260
        var configuration = StitchConfiguration()
        configuration.expectedStep = step

        let (session, outcomes) = try run(
            .periodic(period: 40), step: step, frames: 6, configuration: configuration
        )
        let result = session.finish()

        for outcome in outcomes where outcome != .buffered {
            #expect(outcome == .appended(offset: step), "got \(outcome)")
        }
        #expect(result.offsets.allSatisfy { $0 == step }, "measured \(result.offsets)")
    }

    @Test("A frame of a different size is refused")
    func refusesResizedFrame() throws {
        let document = SyntheticDocument.prose()
        let session = try StitchSession(
            firstFrame: document.cgImage(at: 0, height: viewport), pixelScale: .x1
        )
        let outcome = session.add(document.cgImage(at: 300, height: viewport - 40))
        guard case .unreliable(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("changed size"))
    }

    @Test("A session ended before the buffer filled still produces its frames")
    func finishesEarly() throws {
        let document = SyntheticDocument.prose()
        let session = try StitchSession(
            firstFrame: document.cgImage(at: 0, height: viewport), pixelScale: .x1
        )
        let result = session.finish()
        #expect(result.rows == viewport)
        #expect(result.frameCount == 1)
    }
}
