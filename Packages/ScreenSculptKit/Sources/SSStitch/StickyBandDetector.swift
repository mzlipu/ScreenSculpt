// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

/// Rows pinned to the top or bottom of the viewport that do not scroll.
public struct StickyBands: Sendable, Equatable {
    public let top: Int
    public let bottom: Int

    public static let none = StickyBands(top: 0, bottom: 0)

    public init(top: Int, bottom: Int) {
        self.top = top
        self.bottom = bottom
    }

    public var isEmpty: Bool { top == 0 && bottom == 0 }
}

public struct StickyBandOptions: Sendable {
    /// Mean absolute luminance difference below which a row counts as unchanged.
    /// Not zero: subpixel text rendering and compression make identical content
    /// differ by a step or two.
    public var tolerance: Double = 2.0
    /// A band may not exceed this share of the frame. Without a cap, a frame
    /// pair that did not move at all reads as entirely sticky.
    public var maximumFraction: Double = 0.4
    /// Frame pairs that must agree. A single pair cannot tell a fixed header
    /// from content that happened not to change.
    public var requiredPairs: Int = 2
    public init() {}
}

/// Finds fixed headers and footers before alignment runs.
///
/// This has to happen first. A 60-pixel toolbar that never moves is identical in
/// every frame, so it correlates perfectly at an offset of zero and drags the
/// whole search toward "nothing moved" — the frames then stack on top of each
/// other and the stitch collapses.
public enum StickyBandDetector {

    public static func detect(
        in frames: [GrayFrame], options: StickyBandOptions = StickyBandOptions()
    ) -> StickyBands {
        guard frames.count >= 2 else { return .none }
        let height = frames[0].height
        guard frames.allSatisfy({ $0.height == height && $0.width == frames[0].width })
        else { return .none }

        let cap = Int(Double(height) * options.maximumFraction)
        guard cap > 0 else { return .none }

        var top = cap
        var bottom = cap
        var pairs = 0

        for index in 1..<frames.count {
            let before = frames[index - 1]
            let after = frames[index]

            var leading = 0
            while leading < cap,
                  before.rowDifference(leading, against: after, row: leading)
                    <= options.tolerance {
                leading += 1
            }

            var trailing = 0
            while trailing < cap {
                let row = height - 1 - trailing
                guard before.rowDifference(row, against: after, row: row)
                        <= options.tolerance else { break }
                trailing += 1
            }

            top = min(top, leading)
            bottom = min(bottom, trailing)
            pairs += 1
        }

        guard pairs >= options.requiredPairs else { return .none }

        // A run of blank rows is unchanged between frames too, but it is empty
        // space scrolling past, not a fixed header. Telling them apart needs the
        // band's own content: anything with structure varies down its height.
        let reference = frames[0]
        if !hasVerticalStructure(reference, from: 0, count: top, options: options) { top = 0 }
        if !hasVerticalStructure(
            reference, from: height - bottom, count: bottom, options: options
        ) { bottom = 0 }

        return StickyBands(top: top, bottom: bottom)
    }

    private static func hasVerticalStructure(
        _ frame: GrayFrame, from start: Int, count: Int, options: StickyBandOptions
    ) -> Bool {
        guard count >= 2 else { return false }
        for row in (start + 1)..<(start + count)
        where frame.rowDifference(row, against: frame, row: row - 1) > options.tolerance {
            return true
        }
        return false
    }
}
