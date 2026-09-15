// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSAnnotations
import SSGeometry

/// Alignment guides while dragging.
///
/// Candidates are gathered **once at drag start**, not per mouse-move: the set
/// of other objects cannot change mid-drag, and rebuilding it on every event
/// would make dragging cost O(objects) per frame.
///
/// The threshold arrives in image pixels, converted from a fixed number of view
/// points by the caller, so snapping feels the same at 25% and at 3200%.
struct SnapEngine {

    private let verticals: [ImagePx]
    private let horizontals: [ImagePx]
    private let threshold: Double

    /// Guides that were actually hit on the last adjustment, for drawing.
    private(set) var activeVertical: ImagePx?
    private(set) var activeHorizontal: ImagePx?

    init(
        candidates: [SnapCandidate],
        canvasBounds: ImageRect,
        threshold: ImagePx
    ) {
        var verticals = candidates.filter { $0.axis == .vertical }.map(\.position)
        var horizontals = candidates.filter { $0.axis == .horizontal }.map(\.position)

        // The image edges and centre are guides too — often the ones people
        // most want when placing a single object on an empty screenshot.
        verticals += [canvasBounds.minX, canvasBounds.midX, canvasBounds.maxX]
        horizontals += [canvasBounds.minY, canvasBounds.midY, canvasBounds.maxY]

        self.verticals = verticals.sorted()
        self.horizontals = horizontals.sorted()
        self.threshold = threshold.value
    }

    /// Nudge `origin` so the moved box aligns with a nearby guide.
    ///
    /// Tests the box's leading edge, centre and trailing edge against every
    /// candidate, and takes the closest — so an object can snap by any of its
    /// edges rather than only its origin.
    mutating func adjust(origin: ImagePoint, size: ImageSize) -> ImagePoint {
        activeVertical = nil
        activeHorizontal = nil

        var result = origin

        if let (guide, delta) = bestMatch(
            in: verticals,
            edges: [origin.x.value, origin.x.value + size.width.value / 2,
                    origin.x.value + size.width.value]
        ) {
            result.x = ImagePx(origin.x.value + delta)
            activeVertical = guide
        }

        if let (guide, delta) = bestMatch(
            in: horizontals,
            edges: [origin.y.value, origin.y.value + size.height.value / 2,
                    origin.y.value + size.height.value]
        ) {
            result.y = ImagePx(origin.y.value + delta)
            activeHorizontal = guide
        }

        return result
    }

    /// Closest guide to any of `edges`, and how far to move to reach it.
    private func bestMatch(
        in guides: [ImagePx], edges: [Double]
    ) -> (guide: ImagePx, delta: Double)? {
        var best: (guide: ImagePx, delta: Double)?
        for guide in guides {
            for edge in edges {
                let delta = guide.value - edge
                if abs(delta) <= threshold, abs(delta) < abs(best?.delta ?? .infinity) {
                    best = (guide, delta)
                }
            }
        }
        return best
    }
}
