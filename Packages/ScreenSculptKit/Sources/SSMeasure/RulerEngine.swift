// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSGeometry

public enum Axis: Sendable { case horizontal, vertical }

/// What the ruler found.
public struct RulerReading: Sendable, Equatable {
    public let axis: Axis
    /// Span in image pixels.
    public let length: ImagePx
    /// Endpoints of the measured span, for drawing.
    public let start: ImagePoint
    public let end: ImagePoint
    /// True when this is the gap *between* two elements rather than the extent
    /// of one.
    public let isGap: Bool

    public init(
        axis: Axis, length: ImagePx, start: ImagePoint, end: ImagePoint, isGap: Bool
    ) {
        self.axis = axis
        self.length = length
        self.start = start
        self.end = end
        self.isGap = isGap
    }
}

/// Finds element extents and the gaps between them.
///
/// Works on the cached luminance plane with 1-D scanline walks, not Core Image
/// or Vision. Two reasons: the numbers must be the file's own, and the walk has
/// to complete between mouse-moves — a 2000-pixel scan is microseconds, whereas
/// a GPU round-trip per frame is visibly laggy.
public enum RulerEngine {

    /// Luminance step that counts as an edge, out of 255.
    ///
    /// Adjustable because a threshold that finds every border on a high-contrast
    /// UI drowns in noise on a photograph.
    public static let defaultThreshold: Float = 24

    /// Measure from `origin` along `axis`.
    ///
    /// If the cursor sits on flat colour, this measures the run of that colour
    /// — the gap between whatever bounds it. If it sits on or near an edge, it
    /// measures the element instead.
    public static func measure(
        from origin: ImagePoint,
        axis: Axis,
        in buffer: PixelBuffer,
        threshold: Float = defaultThreshold
    ) -> RulerReading? {
        let x = Int(origin.x.value), y = Int(origin.y.value)
        guard buffer.contains(x: x, y: y) else { return nil }

        let reference = buffer.luma(x: x, y: y)
        let (before, after) = runExtent(
            from: (x, y), axis: axis, reference: reference,
            buffer: buffer, threshold: threshold
        )

        let start: ImagePoint
        let end: ImagePoint
        switch axis {
        case .horizontal:
            start = ImagePoint(x: ImagePx(Double(before)), y: origin.y)
            end = ImagePoint(x: ImagePx(Double(after + 1)), y: origin.y)
        case .vertical:
            start = ImagePoint(x: origin.x, y: ImagePx(Double(before)))
            end = ImagePoint(x: origin.x, y: ImagePx(Double(after + 1)))
        }

        let length = axis == .horizontal
            ? end.x - start.x
            : end.y - start.y

        return RulerReading(
            axis: axis, length: length, start: start, end: end,
            // A run of uniform colour bounded on both sides is a gap; an
            // element is what the boundaries themselves belong to.
            isGap: true
        )
    }

    /// Walk both directions until the colour changes by more than `threshold`.
    private static func runExtent(
        from point: (x: Int, y: Int),
        axis: Axis,
        reference: Float,
        buffer: PixelBuffer,
        threshold: Float
    ) -> (before: Int, after: Int) {
        let limit = axis == .horizontal ? buffer.width : buffer.height
        let position = axis == .horizontal ? point.x : point.y

        func luma(_ index: Int) -> Float {
            axis == .horizontal
                ? buffer.luma(x: index, y: point.y)
                : buffer.luma(x: point.x, y: index)
        }

        var before = position
        while before > 0, abs(luma(before - 1) - reference) <= threshold {
            before -= 1
        }

        var after = position
        while after < limit - 1, abs(luma(after + 1) - reference) <= threshold {
            after += 1
        }

        return (before, after)
    }

    /// Nearest edge in one direction, or nil if the scan runs off the image.
    public static func nextEdge(
        from origin: ImagePoint,
        axis: Axis,
        forward: Bool,
        in buffer: PixelBuffer,
        threshold: Float = defaultThreshold
    ) -> ImagePx? {
        let x = Int(origin.x.value), y = Int(origin.y.value)
        guard buffer.contains(x: x, y: y) else { return nil }

        let limit = axis == .horizontal ? buffer.width : buffer.height
        let start = axis == .horizontal ? x : y
        let step = forward ? 1 : -1

        var previous = axis == .horizontal ? buffer.luma(x: x, y: y) : buffer.luma(x: x, y: y)
        var index = start

        while index + step >= 0, index + step < limit {
            index += step
            let current = axis == .horizontal
                ? buffer.luma(x: index, y: y)
                : buffer.luma(x: x, y: index)
            if abs(current - previous) > threshold { return ImagePx(Double(index)) }
            previous = current
        }
        return nil
    }
}

/// Snaps a marquee outward to the edges of whatever it is sitting on.
public enum ElementFitter {

    /// Adjust each edge of `rect` independently.
    ///
    /// An edge that finds no confident boundary is **left exactly where it
    /// was**. A partial snap is far better than a confident wrong one — this
    /// rule is the difference between a feature people trust and one they turn
    /// off after the first surprise.
    public static func fit(
        _ rect: ImageRect,
        in buffer: PixelBuffer,
        threshold: Float = RulerEngine.defaultThreshold
    ) -> ImageRect {
        guard !rect.isEmpty else { return rect }

        let midY = Int(rect.midY.value)
        let midX = Int(rect.midX.value)

        let left = scanEdge(
            Scan(start: Int(rect.minX.value), direction: -1, along: midY, axis: .horizontal),
            buffer: buffer, threshold: threshold
        )
        let right = scanEdge(
            Scan(start: Int(rect.maxX.value), direction: 1, along: midY, axis: .horizontal),
            buffer: buffer, threshold: threshold
        )
        let top = scanEdge(
            Scan(start: Int(rect.minY.value), direction: -1, along: midX, axis: .vertical),
            buffer: buffer, threshold: threshold
        )
        let bottom = scanEdge(
            Scan(start: Int(rect.maxY.value), direction: 1, along: midX, axis: .vertical),
            buffer: buffer, threshold: threshold
        )

        let minX = left.map { Double($0) } ?? rect.minX.value
        let maxX = right.map { Double($0) } ?? rect.maxX.value
        let minY = top.map { Double($0) } ?? rect.minY.value
        let maxY = bottom.map { Double($0) } ?? rect.maxY.value

        guard maxX > minX, maxY > minY else { return rect }
        return ImageRect(
            x: ImagePx(minX), y: ImagePx(minY),
            width: ImagePx(maxX - minX), height: ImagePx(maxY - minY)
        )
    }

    /// One outward scan along a row or column.
    private struct Scan {
        let start: Int
        let direction: Int
        let along: Int
        let axis: Axis
        var maxDistance = 240
    }

    /// Search outward for a boundary, giving up after a bounded distance.
    private static func scanEdge(
        _ scan: Scan, buffer: PixelBuffer, threshold: Float
    ) -> Int? {
        let start = scan.start, direction = scan.direction
        let other = scan.along, axis = scan.axis
        let limit = axis == .horizontal ? buffer.width : buffer.height
        func luma(_ index: Int) -> Float {
            axis == .horizontal
                ? buffer.luma(x: index, y: other)
                : buffer.luma(x: other, y: index)
        }
        guard start >= 0, start < limit else { return nil }

        var previous = luma(start)
        var index = start
        for _ in 0..<scan.maxDistance {
            let next = index + direction
            guard next >= 0, next < limit else { return nil }
            let current = luma(next)
            if abs(current - previous) > threshold {
                // Stop on the boundary itself, so the marquee lands on the
                // element rather than one pixel into its neighbour.
                return direction > 0 ? next : next + 1
            }
            previous = current
            index = next
        }
        return nil
    }
}
