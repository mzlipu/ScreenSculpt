// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import Vision

/// One recognised run of text, already in image-pixel coordinates.
public struct TextBlock: Sendable, Equatable {
    public let string: String
    /// Top-left origin, Y down, image pixels — the app's convention, converted
    /// here so no caller ever sees Vision's normalised bottom-left rects.
    public let rect: ImageRect
    public let confidence: Float

    public init(string: String, rect: ImageRect, confidence: Float) {
        self.string = string
        self.rect = rect
        self.confidence = confidence
    }
}

public struct RecognizedText: Sendable {
    public let blocks: [TextBlock]
    /// Blocks joined in reading order.
    public let plainText: String

    public init(blocks: [TextBlock], plainText: String) {
        self.blocks = blocks
        self.plainText = plainText
    }

    public var isEmpty: Bool { blocks.isEmpty }
    public var meanConfidence: Float {
        blocks.isEmpty ? 0 : blocks.map(\.confidence).reduce(0, +) / Float(blocks.count)
    }
}

public enum RecognitionError: Error, LocalizedError {
    case regionTooLarge(ImageSize)
    case regionEmpty
    case noTextFound
    case failed(any Error)

    public var errorDescription: String? {
        switch self {
        case .regionTooLarge:
            "That area is too large to recognise. Select a smaller one."
        case .regionEmpty:
            "That area looks empty."
        case .noTextFound:
            "No text found."
        case .failed(let error):
            "Text recognition failed: \(error.localizedDescription)"
        }
    }
}

/// Text recognition over a captured image.
public struct TextRecognizer: Sendable {

    /// Above this, Vision gets slow enough to feel broken and the result is
    /// rarely what the user wanted anyway.
    public static let maximumPixels = 40_000_000

    public var languages: [String]
    public var usesLanguageCorrection: Bool
    public var removeLineBreaks: Bool

    public init(
        languages: [String] = ["en-US"],
        usesLanguageCorrection: Bool = true,
        removeLineBreaks: Bool = false
    ) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.removeLineBreaks = removeLineBreaks
    }

    /// Languages this OS can actually recognise.
    ///
    /// Queried at runtime rather than hardcoded. A fixed list drifts against the
    /// OS and produces the "offered in preferences but unsupported here" class
    /// of bug.
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
    }

    public func recognize(in image: RasterImage) throws -> RecognizedText {
        let width = image.cgImage.width
        let height = image.cgImage.height
        guard width > 0, height > 0 else { throw RecognitionError.regionEmpty }
        guard width * height <= Self.maximumPixels else {
            throw RecognitionError.regionTooLarge(image.size)
        }

        let request = VNRecognizeTextRequest()
        // Revisions 1 and 2 are deprecated as of macOS 15; pinning 3 keeps
        // results stable rather than shifting under a future OS default.
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.recognitionLanguages = languages
        // Small UI text matters here more than in most Vision uses.
        request.minimumTextHeight = 0

        let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw RecognitionError.failed(error)
        }

        let observations = request.results ?? []
        guard !observations.isEmpty else { throw RecognitionError.noTextFound }

        let blocks = observations.compactMap { observation -> TextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextBlock(
                string: candidate.string,
                rect: Self.imageRect(
                    from: observation.boundingBox, width: width, height: height
                ),
                confidence: candidate.confidence
            )
        }
        guard !blocks.isEmpty else { throw RecognitionError.noTextFound }

        let ordered = ReadingOrder.sort(blocks)
        return RecognizedText(
            blocks: ordered,
            plainText: ReadingOrder.join(ordered, removingLineBreaks: removeLineBreaks)
        )
    }

    /// Vision's normalised, **bottom-left-origin** rect → image pixels, top-left.
    ///
    /// This is the single most common Vision mistake and it fails silently: the
    /// text is found correctly and the boxes land in the wrong half of the
    /// image. A test renders text in one known quadrant and asserts the result
    /// comes back in that quadrant.
    static func imageRect(from normalized: CGRect, width: Int, height: Int) -> ImageRect {
        let pixels = VNImageRectForNormalizedRect(normalized, width, height)
        return ImageRect(
            x: ImagePx(pixels.minX),
            y: ImagePx(Double(height) - pixels.maxY),
            width: ImagePx(pixels.width),
            height: ImagePx(pixels.height)
        )
    }
}
