// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Accelerate
import Foundation

/// How far a frame moved, and how much that answer can be trusted.
public struct ScrollAlignment: Sendable, Equatable {

    public enum Confidence: String, Sendable {
        /// One clear peak, well clear of everything else.
        case high
        /// A peak, but a weak one — worth verifying against real pixels.
        case low
        /// Several near-equal peaks: repeating rows, or a periodic pattern.
        case ambiguous
        /// Not enough variation to say anything. A blank region, typically.
        case indeterminate
    }

    /// Rows by which `next` sits further down the document than `previous`.
    public let offset: Int
    /// Normalised correlation at `offset`, in -1…1.
    public let score: Double
    /// The best competing peak, or -1 when there was none.
    public let runnerUp: Double
    /// Peaks within `ambiguityEpsilon` of the winner, excluding the winner.
    public let contenders: Int
    public let confidence: Confidence

    public var margin: Double { score - runnerUp }
}

public struct CorrelationOptions: Sendable {

    /// Smallest movement worth reporting. Zero would let a frame match itself.
    public var minimumOffset: Int = 1
    /// Largest movement to consider; `nil` searches as far as the frames allow.
    public var maximumOffset: Int?
    /// How many rows of overlap to score. Capping this is what keeps a
    /// full-range search cheap; the verifier checks the whole overlap after.
    public var compareRows: Int = 256
    /// Below this the sample is too short to mean anything.
    public var minimumOverlapRows: Int = 48
    /// First row of `next` to sample — set past a sticky header.
    public var sampleOrigin: Int = 0
    public var minimumScore: Double = 0.55
    public var minimumMargin: Double = 0.03
    /// Peaks nearer than this to the winner are the same peak.
    public var peakSeparation: Int = 6
    public var ambiguityEpsilon: Double = 0.02
    /// Per-element variance below which correlation is meaningless.
    public var minimumVariance: Float = 4

    public init() {}
}

/// Finds the vertical offset between two frames of a scroll.
///
/// Reduces both frames to row descriptors and scores every candidate offset,
/// keeping the whole curve rather than just the winner. That curve is the point:
/// a single best-match number cannot distinguish a confident answer from a
/// coin-flip between two equally good ones, and repeating list rows — which is
/// most of what people scroll-capture — produce exactly that coin flip.
public enum ScrollCorrelator {

    /// Align two frames captured in document order: `previous` first, `next`
    /// after scrolling **down**.
    ///
    /// For an upward scroll, pass the frames the other way round; the geometry
    /// is symmetric and a signed offset would only invite sign errors at the
    /// call sites.
    public static func align(
        previous: RowDescriptors,
        next: RowDescriptors,
        options: CorrelationOptions = CorrelationOptions()
    ) -> ScrollAlignment? {
        guard previous.bucketCount == next.bucketCount else { return nil }
        let buckets = previous.bucketCount
        let origin = max(0, options.sampleOrigin)

        let ceiling = min(
            options.maximumOffset ?? previous.rowCount,
            previous.rowCount - origin - options.minimumOverlapRows
        )
        guard ceiling >= options.minimumOffset else { return nil }

        // The window in `next` is the same for every candidate, so its sums are
        // computed once rather than once per offset.
        let sampleRows = min(
            options.compareRows,
            next.rowCount - origin,
            previous.rowCount - origin - options.minimumOffset
        )
        guard sampleRows >= options.minimumOverlapRows else { return nil }

        var scores = [Double](repeating: -1, count: ceiling + 1)
        var indeterminate = true

        next.values.withUnsafeBufferPointer { nextValues in
            previous.values.withUnsafeBufferPointer { previousValues in
                let count = vDSP_Length(sampleRows * buckets)
                let nextBase = nextValues.baseAddress! + origin * buckets

                var sumB: Float = 0
                var sumSquaresB: Float = 0
                vDSP_sve(nextBase, 1, &sumB, count)
                vDSP_svesq(nextBase, 1, &sumSquaresB, count)
                let total = Float(count)
                let varianceB = sumSquaresB - sumB * sumB / total
                guard varianceB / total >= options.minimumVariance else { return }

                for offset in options.minimumOffset...ceiling {
                    let start = (origin + offset) * buckets
                    guard start + Int(count) <= previousValues.count else { break }
                    let base = previousValues.baseAddress! + start

                    var sumA: Float = 0
                    var sumSquaresA: Float = 0
                    var dot: Float = 0
                    vDSP_sve(base, 1, &sumA, count)
                    vDSP_svesq(base, 1, &sumSquaresA, count)
                    vDSP_dotpr(base, 1, nextBase, 1, &dot, count)

                    let varianceA = sumSquaresA - sumA * sumA / total
                    guard varianceA / total >= options.minimumVariance else { continue }

                    indeterminate = false
                    let covariance = dot - sumA * sumB / total
                    scores[offset] = Double(covariance / (varianceA * varianceB).squareRoot())
                }
            }
        }

        guard !indeterminate else {
            return ScrollAlignment(
                offset: 0, score: 0, runnerUp: -1, contenders: 0, confidence: .indeterminate
            )
        }
        return summarise(scores, from: options.minimumOffset, options: options)
    }

    /// Turn the score curve into a verdict.
    private static func summarise(
        _ scores: [Double], from lowerBound: Int, options: CorrelationOptions
    ) -> ScrollAlignment? {
        var bestOffset = -1
        var best = -Double.infinity
        for offset in lowerBound..<scores.count where scores[offset] > best {
            best = scores[offset]
            bestOffset = offset
        }
        guard bestOffset >= 0, best > -Double.infinity else { return nil }

        var runnerUp = -1.0
        var contenders = 0
        for offset in lowerBound..<scores.count {
            guard abs(offset - bestOffset) >= options.peakSeparation else { continue }
            guard isLocalMaximum(scores, at: offset, lowerBound: lowerBound) else { continue }
            runnerUp = max(runnerUp, scores[offset])
            if scores[offset] >= best - options.ambiguityEpsilon { contenders += 1 }
        }

        let confidence: ScrollAlignment.Confidence
        if best < options.minimumScore {
            confidence = .low
        } else if contenders > 0 || best - runnerUp < options.minimumMargin {
            confidence = .ambiguous
        } else {
            confidence = .high
        }

        return ScrollAlignment(
            offset: bestOffset, score: best, runnerUp: runnerUp,
            contenders: contenders, confidence: confidence
        )
    }

    private static func isLocalMaximum(
        _ scores: [Double], at offset: Int, lowerBound: Int
    ) -> Bool {
        let left = offset > lowerBound ? scores[offset - 1] : -.infinity
        let right = offset + 1 < scores.count ? scores[offset + 1] : -.infinity
        return scores[offset] >= left && scores[offset] >= right
    }
}
