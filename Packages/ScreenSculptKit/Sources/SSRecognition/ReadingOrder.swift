// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSGeometry

/// Puts recognised blocks into the order a person would read them.
///
/// Vision returns observations in no guaranteed order, so this is not optional
/// polish: without it, copied text from a two-column layout comes out
/// interleaved and useless.
public enum ReadingOrder {

    /// Group into lines, order the lines, order within each line.
    public static func sort(_ blocks: [TextBlock]) -> [TextBlock] {
        guard blocks.count > 1 else { return blocks }

        let columns = detectColumns(blocks)
        var result: [TextBlock] = []
        for column in columns {
            for line in lines(in: column) {
                result += line.sorted { $0.rect.minX < $1.rect.minX }
            }
        }
        return result
    }

    /// Cluster blocks whose vertical spans overlap substantially.
    ///
    /// Overlap rather than a shared baseline, because a line often mixes sizes —
    /// a heading beside a badge, say — and baselines then disagree while the
    /// spans still clearly belong together.
    static func lines(in blocks: [TextBlock]) -> [[TextBlock]] {
        let sorted = blocks.sorted { $0.rect.minY < $1.rect.minY }
        var result: [[TextBlock]] = []

        for block in sorted {
            if let index = result.indices.last, sharesLine(block, with: result[index]) {
                result[index].append(block)
            } else {
                result.append([block])
            }
        }
        return result
    }

    private static func sharesLine(_ block: TextBlock, with line: [TextBlock]) -> Bool {
        guard let reference = line.last else { return false }
        let a = block.rect, b = reference.rect
        let overlap = min(a.maxY.value, b.maxY.value) - max(a.minY.value, b.minY.value)
        let smaller = min(a.height.value, b.height.value)
        guard smaller > 0 else { return false }
        return overlap / smaller > 0.5
    }

    /// Split into columns separated by a vertical gutter.
    ///
    /// A gutter is a band of x with no text at all, wide relative to the
    /// content. Without this step a two-column page reads across the columns
    /// rather than down them.
    static func detectColumns(_ blocks: [TextBlock]) -> [[TextBlock]] {
        guard blocks.count > 3 else { return [blocks] }

        let minX = blocks.map(\.rect.minX.value).min() ?? 0
        let maxX = blocks.map(\.rect.maxX.value).max() ?? 0
        let span = maxX - minX
        guard span > 0 else { return [blocks] }

        // A gutter narrower than this is just word spacing.
        let minimumGutter = span * 0.06

        let intervals = blocks
            .map { ($0.rect.minX.value, $0.rect.maxX.value) }
            .sorted { $0.0 < $1.0 }

        var boundaries: [Double] = []
        var reach = intervals[0].1
        for (start, end) in intervals.dropFirst() {
            if start - reach > minimumGutter {
                boundaries.append((reach + start) / 2)
            }
            reach = max(reach, end)
        }
        guard !boundaries.isEmpty else { return [blocks] }

        var columns = [[TextBlock]](repeating: [], count: boundaries.count + 1)
        for block in blocks {
            let centre = block.rect.midX.value
            let index = boundaries.firstIndex { centre < $0 } ?? boundaries.count
            columns[index].append(block)
        }
        return columns.filter { !$0.isEmpty }
    }

    /// Join blocks into text.
    ///
    /// With `removingLineBreaks`, wrapped lines are rejoined with a space while
    /// deliberate breaks are kept. A line is treated as wrapped when it does not
    /// end in sentence punctuation and reaches near the right edge of its
    /// column — rejoining everything would destroy lists and code.
    public static func join(_ blocks: [TextBlock], removingLineBreaks: Bool) -> String {
        let grouped = lines(in: blocks)
        let lineTexts = grouped.map { line in
            line.sorted { $0.rect.minX < $1.rect.minX }
                .map(\.string)
                .joined(separator: " ")
        }
        guard removingLineBreaks else { return lineTexts.joined(separator: "\n") }

        let rightEdge = blocks.map(\.rect.maxX.value).max() ?? 0
        var output = ""
        for (index, text) in lineTexts.enumerated() {
            output += text
            guard index < lineTexts.count - 1 else { break }

            let lineRight = grouped[index].map(\.rect.maxX.value).max() ?? 0
            let reachesEdge = rightEdge > 0 && lineRight / rightEdge > 0.9
            let endsSentence = text.last.map { ".!?:;".contains($0) } ?? false

            output += (reachesEdge && !endsSentence) ? " " : "\n"
        }
        return output
    }
}
