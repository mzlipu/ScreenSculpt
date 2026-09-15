// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation
import SSAnnotations
import SSDocument
import SSGeometry
import SSImaging
import Testing

@testable import SSEditorUI

@MainActor
private func makeStore() -> DocumentStore {
    let context = CGContext(
        data: nil, width: 400, height: 400,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
    return DocumentStore(
        image: RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)
    )
}

private func point(_ x: Double, _ y: Double) -> ImagePoint {
    ImagePoint(x: ImagePx(x), y: ImagePx(y))
}

/// Replays what the canvas does for a press-drag-release.
@MainActor
private func drawGesture(
    _ kind: AnnotationKind,
    with tools: ToolController,
    from start: ImagePoint = point(50, 50),
    to end: ImagePoint = point(220, 180)
) {
    var snap: SnapEngine?
    tools.tool = .draw(kind)
    _ = tools.begin(at: start, tolerance: 6, modifiers: [])
    // Several intermediate moves, because stroke tools accumulate points.
    for step in 1...5 {
        let t = Double(step) / 5
        tools.drag(
            to: ImagePoint(
                x: ImagePx(start.x.value + (end.x.value - start.x.value) * t),
                y: ImagePx(start.y.value + (end.y.value - start.y.value) * t)
            ),
            modifiers: [],
            snap: &snap
        )
    }
    tools.end()
}

@Suite("Drawing gestures")
@MainActor
struct ToolControllerTests {

    /// The bug the user hit: four tools produced nothing because the object was
    /// discarded on mouse-up.
    @Test("Every tool leaves an annotation behind", arguments: AnnotationKind.allCases)
    func gestureProducesAnnotation(_ kind: AnnotationKind) {
        let store = makeStore()
        let tools = ToolController(store: store)
        drawGesture(kind, with: tools)

        #expect(store.annotations.count == 1, "\(kind.label) produced nothing")
        #expect(store.annotations.all.first?.kind == kind)
    }

    @Test("A stroke keeps the points it was drawn through")
    func strokeKeepsPoints() {
        let store = makeStore()
        let tools = ToolController(store: store)
        drawGesture(.freehand, with: tools)

        guard case .freehand(let body) = store.annotations.all.first?.body else {
            Issue.record("expected a freehand body")
            return
        }
        #expect(body.points.count >= 2)
        // Simplification must not collapse the stroke to a single point.
        #expect(!body.bounds.isEmpty)
    }

    @Test("A click with no drag is discarded for shape tools")
    func degenerateShapeDiscarded() {
        // Otherwise a stray click litters the canvas with invisible objects.
        let store = makeStore()
        let tools = ToolController(store: store)
        drawGesture(.rectangle, with: tools, from: point(50, 50), to: point(51, 51))
        #expect(store.annotations.isEmpty)
    }

    @Test("A click does place a counter and a text label")
    func clickPlacesPointTools() {
        // These two are placed rather than dragged, so the degenerate check
        // must not apply to them.
        for kind in [AnnotationKind.counter, .text] {
            let store = makeStore()
            let tools = ToolController(store: store)
            drawGesture(kind, with: tools, from: point(50, 50), to: point(50, 50))
            #expect(store.annotations.count == 1, "\(kind.label) was discarded")
        }
    }

    @Test("Drawing selects what was just drawn")
    func newObjectIsSelected() {
        let store = makeStore()
        let tools = ToolController(store: store)
        drawGesture(.arrow, with: tools)
        #expect(store.selectedAnnotation != nil)
    }

    @Test("A drag is a single undo step")
    func dragIsOneUndoEntry() {
        let store = makeStore()
        let tools = ToolController(store: store)
        drawGesture(.rectangle, with: tools)
        #expect(store.annotations.count == 1)

        store.undo()
        #expect(store.annotations.isEmpty, "one undo should remove the whole shape")
    }

    @Test("Moving an existing object is also one undo step")
    func moveIsOneUndoEntry() {
        let store = makeStore()
        let tools = ToolController(store: store)
        drawGesture(.rectangle, with: tools)
        let originalX = store.annotations.all.first!.bounds.minX

        var snap: SnapEngine?
        tools.tool = .select
        _ = tools.begin(at: point(50, 50), tolerance: 8, modifiers: [])
        for step in 1...4 {
            tools.drag(
                to: point(50 + Double(step) * 10, 50), modifiers: [], snap: &snap
            )
        }
        tools.end()

        #expect(store.annotations.all.first!.bounds.minX != originalX)
        store.undo()
        #expect(store.annotations.all.first!.bounds.minX == originalX)
    }

    @Test("Escape during a draw removes the half-made object")
    func cancelRemovesInProgress() {
        let store = makeStore()
        let tools = ToolController(store: store)
        var snap: SnapEngine?
        tools.tool = .draw(.oval)
        _ = tools.begin(at: point(10, 10), tolerance: 6, modifiers: [])
        tools.drag(to: point(100, 100), modifiers: [], snap: &snap)
        tools.cancel()
        #expect(store.annotations.isEmpty)
    }

    @Test("Counters number themselves in sequence")
    func counterSequence() {
        let store = makeStore()
        let tools = ToolController(store: store)
        for _ in 1...3 {
            drawGesture(.counter, with: tools, from: point(50, 50), to: point(50, 50))
        }
        let numbers = store.annotations.all.compactMap { annotation -> Int? in
            if case .counter(let body) = annotation.body { return body.number }
            return nil
        }
        #expect(numbers.sorted() == [1, 2, 3])
    }
}
