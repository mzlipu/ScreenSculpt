// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import CoreText
import Foundation
import SSGeometry
import SSImaging
import Testing

@testable import SSRecognition

// MARK: - Fixtures

/// Renders text into a bitmap so recognition can be exercised without a
/// screenshot or a window server.
private func imageWithText(
    _ runs: [(text: String, at: CGPoint)],
    width: Int = 600,
    height: Int = 400,
    fontSize: Double = 36
) -> RasterImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(fontSize), nil)
    for run in runs {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: run.text, attributes: attributes)
        )
        context.textPosition = run.at
        CTLineDraw(line, context)
    }
    return RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)
}

private func block(_ text: String, x: Double, y: Double, w: Double, h: Double) -> TextBlock {
    TextBlock(
        string: text,
        rect: ImageRect(x: ImagePx(x), y: ImagePx(y), width: ImagePx(w), height: ImagePx(h)),
        confidence: 1
    )
}

/// Whether tests that actually run Vision should execute.
///
/// They hang on a GitHub macOS runner — measured: the rest of the suite
/// finishes in under two minutes there while these sit until the step is
/// killed. Vision wants language models a fresh runner has never cached, and
/// fetching or compiling them is not something a build machine can be relied on
/// to do.
///
/// Gated rather than deleted, and gated by environment rather than by
/// `#if DEBUG`: on a real Mac these are the only tests that prove recognition
/// works at all, and they must keep running there. CI sets `SS_SKIP_VISION`.
/// They report as skipped, not as passed — a suite that silently tests nothing
/// is worse than one that is honestly absent.
let canRunVision = ProcessInfo.processInfo.environment["SS_SKIP_VISION"] == nil

// MARK: - Coordinates

@Suite("Vision coordinate conversion")
struct CoordinateTests {

    /// The trap: Vision's rects are normalised with a bottom-left origin, while
    /// everything in this app is top-left in pixels. Getting it wrong finds the
    /// text correctly and puts the boxes in the wrong half — which for redaction
    /// is a privacy failure, not a cosmetic one.
    @Test("A normalised bottom-left rect converts to a top-left pixel rect")
    func flipIsCorrect() {
        // Vision rect covering the TOP-left quarter: y 0.5…1.0 in its space.
        let converted = TextRecognizer.imageRect(
            from: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), width: 400, height: 200
        )
        #expect(converted.minX == ImagePx(0))
        #expect(converted.minY == ImagePx(0), "should land at the TOP")
        #expect(converted.width == ImagePx(200))
        #expect(converted.height == ImagePx(100))
    }

    @Test("A bottom-left Vision rect converts to the bottom of the image")
    func bottomStaysBottom() {
        let converted = TextRecognizer.imageRect(
            from: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), width: 400, height: 200
        )
        #expect(converted.minY == ImagePx(100))
        #expect(converted.maxY == ImagePx(200))
    }

    /// End-to-end version of the same check, with real recognition.
    @Test("Text rendered in one quadrant is reported in that quadrant",
          .enabled(if: canRunVision))
    func quadrantEndToEnd() throws {
        // CTLine draws from a baseline in CG's bottom-up space, so y = 340 of
        // 400 puts this near the TOP of the image.
        let image = imageWithText([("TOPLEFT", CGPoint(x: 30, y: 340))])
        let recognizer = TextRecognizer()

        let result = try recognizer.recognize(in: image)
        let found = try #require(result.blocks.first)

        #expect(found.rect.midY.value < 200, "should be in the top half, got \(found.rect)")
        #expect(found.rect.midX.value < 300, "should be in the left half, got \(found.rect)")
    }
}

// MARK: - Recognition

@Suite("Text recognition")
struct RecognitionTests {

    @Test("Plain text is recognised", .enabled(if: canRunVision))
    func recognisesText() throws {
        let image = imageWithText([("Hello world", CGPoint(x: 40, y: 200))])
        let result = try TextRecognizer().recognize(in: image)
        #expect(result.plainText.lowercased().contains("hello"))
    }

    @Test("An empty image reports no text rather than an empty success",
          .enabled(if: canRunVision))
    func emptyImage() {
        let context = CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        let blank = RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)

        #expect(throws: RecognitionError.self) {
            try TextRecognizer().recognize(in: blank)
        }
    }

    @Test("Supported languages are queried from the OS, not hardcoded",
          .enabled(if: canRunVision))
    func languagesFromOS() {
        let languages = TextRecognizer.supportedLanguages()
        #expect(languages.count > 5)
        #expect(languages.contains { $0.hasPrefix("en") })
    }
}

// MARK: - Reading order

@Suite("Reading order")
struct ReadingOrderTests {

    @Test("Blocks on one line are ordered left to right")
    func withinLine() {
        let shuffled = [
            block("third", x: 200, y: 10, w: 50, h: 20),
            block("first", x: 0, y: 10, w: 50, h: 20),
            block("second", x: 100, y: 12, w: 50, h: 20),
        ]
        let sorted = ReadingOrder.sort(shuffled)
        #expect(sorted.map(\.string) == ["first", "second", "third"])
    }

    @Test("Lines are ordered top to bottom")
    func acrossLines() {
        let shuffled = [
            block("bottom", x: 0, y: 100, w: 50, h: 20),
            block("top", x: 0, y: 0, w: 50, h: 20),
            block("middle", x: 0, y: 50, w: 50, h: 20),
        ]
        #expect(ReadingOrder.sort(shuffled).map(\.string) == ["top", "middle", "bottom"])
    }

    @Test("Blocks of differing size still share a line when their spans overlap")
    func mixedSizesShareALine() {
        // A heading beside a badge: baselines disagree, spans clearly do not.
        let blocks = [
            block("Heading", x: 0, y: 0, w: 120, h: 40),
            block("NEW", x: 140, y: 12, w: 40, h: 16),
        ]
        #expect(ReadingOrder.lines(in: blocks).count == 1)
    }

    /// Without column detection a two-column layout copies out interleaved,
    /// which is worse than useless — it looks plausible and is wrong.
    @Test("Two columns are read down, not across")
    func columnsReadDown() {
        let blocks = [
            block("left-1", x: 0, y: 0, w: 150, h: 20),
            block("right-1", x: 400, y: 0, w: 150, h: 20),
            block("left-2", x: 0, y: 40, w: 150, h: 20),
            block("right-2", x: 400, y: 40, w: 150, h: 20),
        ]
        let sorted = ReadingOrder.sort(blocks).map(\.string)
        #expect(sorted == ["left-1", "left-2", "right-1", "right-2"])
    }

    @Test("A single column is not split by ordinary word spacing")
    func noFalseColumns() {
        let blocks = [
            block("The", x: 0, y: 0, w: 40, h: 20),
            block("quick", x: 48, y: 0, w: 60, h: 20),
            block("brown", x: 116, y: 0, w: 70, h: 20),
        ]
        #expect(ReadingOrder.detectColumns(blocks).count == 1)
    }

    @Test("Line breaks are preserved by default")
    func keepsBreaks() {
        let blocks = [
            block("first line", x: 0, y: 0, w: 200, h: 20),
            block("second line", x: 0, y: 40, w: 200, h: 20),
        ]
        let joined = ReadingOrder.join(blocks, removingLineBreaks: false)
        #expect(joined == "first line\nsecond line")
    }

    @Test("Removing line breaks rejoins wrapped lines but keeps deliberate ones")
    func rejoinsWrappedOnly() {
        let blocks = [
            // Reaches the right edge and does not end a sentence: wrapped.
            block("a wrapped line that runs on", x: 0, y: 0, w: 300, h: 20),
            block("and continues here.", x: 0, y: 40, w: 180, h: 20),
            // Ends a sentence, so the break after it is deliberate.
            block("A new paragraph.", x: 0, y: 80, w: 160, h: 20),
        ]
        let joined = ReadingOrder.join(blocks, removingLineBreaks: true)
        #expect(joined.contains("runs on and continues"), "got: \(joined)")
        #expect(joined.contains("here.\nA new"), "got: \(joined)")
    }
}

// MARK: - Redaction

@Suite("Text region masking")
struct MaskingTests {

    @Test("Text regions are found and sit where the text is", .enabled(if: canRunVision))
    func findsRegions() {
        let image = imageWithText([("SECRET", CGPoint(x: 40, y: 200))])
        let regions = TextRegionMasker.textRegions(in: image)
        #expect(!regions.isEmpty)
        // Baseline y=200 of 400 → middle of the image, top-left origin.
        #expect(regions[0].midY.value > 100)
        #expect(regions[0].midY.value < 300)
    }

    /// The privacy-critical property: redaction must not touch anything the
    /// user did not ask to hide.
    @Test("A region of interest confines results to that region",
          .enabled(if: canRunVision))
    func regionOfInterestIsHonoured() {
        let image = imageWithText([
            ("TOPTEXT", CGPoint(x: 40, y: 340)),
            ("BOTTOMTEXT", CGPoint(x: 40, y: 60)),
        ])
        // Bottom half only, in image coordinates.
        let region = ImageRect(x: 0, y: 200, width: 600, height: 200)
        let regions = TextRegionMasker.textRegions(in: image, within: region)

        #expect(!regions.isEmpty, "should have found the lower text")
        for rect in regions {
            #expect(rect.minY.value >= 195, "leaked outside the region: \(rect)")
        }
    }
}
