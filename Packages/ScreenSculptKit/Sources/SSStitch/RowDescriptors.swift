// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

/// A frame reduced to one short signature per pixel row.
///
/// Each row becomes `bucketCount` horizontal averages, so a 1200-pixel-wide row
/// collapses to 32 numbers. Alignment then compares rows rather than pixels,
/// which is what makes a full-range search affordable.
///
/// Horizontal detail is what gets thrown away, and that is the right thing to
/// lose: scrolling moves content vertically, so a row's horizontal profile is
/// exactly the part that stays constant and identifies it.
public struct RowDescriptors: Sendable {

    public static let defaultBucketCount = 32

    public let rowCount: Int
    public let bucketCount: Int
    /// Row-major, `rowCount * bucketCount` values in 0…255.
    public let values: [Float]

    init(rowCount: Int, bucketCount: Int, values: [Float]) {
        self.rowCount = rowCount
        self.bucketCount = bucketCount
        self.values = values
    }

    public init(_ frame: GrayFrame, bucketCount: Int = RowDescriptors.defaultBucketCount) {
        let buckets = max(1, min(bucketCount, frame.width))
        var values = [Float](repeating: 0, count: frame.height * buckets)

        // Bucket edges are computed per bucket rather than as a fixed stride so
        // a width that does not divide evenly spreads the remainder instead of
        // dropping the last few columns.
        var starts = [Int](repeating: 0, count: buckets + 1)
        for bucket in 0...buckets {
            starts[bucket] = bucket * frame.width / buckets
        }

        frame.pixels.withUnsafeBufferPointer { source in
            values.withUnsafeMutableBufferPointer { destination in
                for row in 0..<frame.height {
                    let rowStart = row * frame.width
                    for bucket in 0..<buckets {
                        let from = starts[bucket]
                        let to = starts[bucket + 1]
                        guard to > from else { continue }
                        var total = 0
                        for x in from..<to { total += Int(source[rowStart + x]) }
                        destination[row * buckets + bucket] =
                            Float(total) / Float(to - from)
                    }
                }
            }
        }

        self.init(rowCount: frame.height, bucketCount: buckets, values: values)
    }
}
