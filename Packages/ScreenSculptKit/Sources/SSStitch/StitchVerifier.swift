// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

/// The result of checking a claimed offset against the actual pixels.
public struct OverlapCheck: Sendable, Equatable {
    /// Mean absolute luminance difference across the overlap, in 0…255 steps.
    public let error: Double
    /// Rows compared. A verdict over a handful of rows means little.
    public let rows: Int
    public let passed: Bool
}

/// Confirms an alignment against full-resolution pixels.
///
/// The correlator works on 32 averages per row, which is what makes it fast and
/// also what makes this step necessary: two different rows can share a
/// horizontal profile. Every alignment is therefore checked here before being
/// committed, whatever confidence the correlator reported — a wrong offset does
/// not look wrong in the output, it looks like a page with a paragraph missing.
public enum StitchVerifier {

    /// Compare the claimed overlap between two frames.
    ///
    /// - Parameters:
    ///   - offset: rows by which `next` sits below `previous`.
    ///   - sticky: bands to exclude, since a fixed header matches at any offset
    ///     and would flatter the result.
    ///   - tolerance: mean absolute error, in luminance steps, still considered
    ///     a match.
    public static func check(
        previous: GrayFrame,
        next: GrayFrame,
        offset: Int,
        sticky: StickyBands = .none,
        tolerance: Double = 6,
        maximumRows: Int = 600
    ) -> OverlapCheck {
        guard
            previous.width == next.width,
            offset > 0,
            offset < previous.height
        else { return OverlapCheck(error: .infinity, rows: 0, passed: false) }

        // Row `r` of `next` pairs with row `r + offset` of `previous`, so both
        // ends have to stay inside their own frame's content region. Bounding
        // only the near side lets the tail of the comparison run into the
        // previous frame's footer, where a fixed band is matched against real
        // content and every correct offset is rejected.
        let firstRow = sticky.top
        let lastRow = min(
            next.height - sticky.bottom,
            previous.height - sticky.bottom - offset
        )
        let available = lastRow - firstRow
        guard available > 0 else {
            return OverlapCheck(error: .infinity, rows: 0, passed: false)
        }

        // Sample evenly across the overlap rather than taking the first N rows:
        // a run at one end can agree by luck, and a sticky element just inside
        // the trimmed band would dominate a contiguous sample.
        let rows = min(available, maximumRows)
        let stride = max(1, available / rows)

        var total = 0.0
        var counted = 0
        var row = firstRow
        while row < firstRow + available, counted < rows {
            total += previous.rowDifference(row + offset, against: next, row: row)
            counted += 1
            row += stride
        }
        guard counted > 0 else {
            return OverlapCheck(error: .infinity, rows: 0, passed: false)
        }

        let error = total / Double(counted)
        return OverlapCheck(error: error, rows: counted, passed: error <= tolerance)
    }
}
