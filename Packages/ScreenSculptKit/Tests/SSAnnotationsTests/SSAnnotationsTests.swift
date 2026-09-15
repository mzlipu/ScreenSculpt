// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import Testing

@testable import SSAnnotations

private let style = AnnotationStyle(color: .red, strokeWidth: 4)

private func point(_ x: Double, _ y: Double) -> ImagePoint {
    ImagePoint(x: ImagePx(x), y: ImagePx(y))
}

// MARK: - Hit testing

@Suite("Hit testing")
struct HitTestTests {

    @Test("An outline rectangle is hit on its edge, not through the middle")
    func outlineIsHollow() {
        // Otherwise a large frame would swallow clicks meant for what it frames.
        let body = RectangleBody(rect: ImageRect(x: 10, y: 10, width: 200, height: 100))
        #expect(body.hitTest(point(10, 60), tolerance: 3, style: style) == .body)
        #expect(body.hitTest(point(110, 60), tolerance: 3, style: style) == nil)
    }

    @Test("A filled rectangle is hit anywhere inside it")
    func filledIsSolid() {
        var filled = style
        filled.fill = .translucent
        let body = RectangleBody(rect: ImageRect(x: 10, y: 10, width: 200, height: 100))
        #expect(body.hitTest(point(110, 60), tolerance: 3, style: filled) == .body)
    }

    @Test("Handles win over the body")
    func handlesTakePrecedence() {
        let body = RectangleBody(rect: ImageRect(x: 10, y: 10, width: 200, height: 100))
        let hit = body.hitTest(point(10, 10), tolerance: 6, style: style)
        #expect(hit == .handle(.corner(.topLeft)))
    }

    @Test("An oval is hit on its curve, not in its bounding-box corners")
    func ovalIsNotItsBoundingBox() {
        let body = OvalBody(rect: ImageRect(x: 0, y: 0, width: 200, height: 200))
        // Dead centre of the left edge is on the curve.
        #expect(body.hitTest(point(0, 100), tolerance: 3, style: style) == .body)
        // A point just inside the bounding-box corner is well off the ellipse,
        // and far enough from the corner handle not to catch it either.
        #expect(body.hitTest(point(18, 18), tolerance: 2, style: style) == nil)
    }

    @Test("A line is hit along its length but not beside it")
    func lineHitTest() {
        let body = LineBody(start: point(0, 0), end: point(100, 100))
        #expect(body.hitTest(point(50, 50), tolerance: 2, style: style) == .body)
        #expect(body.hitTest(point(50, 90), tolerance: 2, style: style) == nil)
    }

    @Test("Hit slop scales with the supplied tolerance")
    func toleranceMatters() {
        // The canvas converts a fixed number of view points into image pixels,
        // so a thin line stays grabbable when zoomed out.
        let body = LineBody(start: point(0, 0), end: point(100, 0))
        #expect(body.hitTest(point(50, 12), tolerance: 1, style: style) == nil)
        #expect(body.hitTest(point(50, 12), tolerance: 20, style: style) == .body)
    }

    @Test("A curved arrow is hit along the curve, not the straight chord")
    func bentArrowFollowsItsCurve() {
        let body = ArrowBody(start: point(0, 0), end: point(200, 0), bend: 0.4)
        // Sampled away from t=0.5, where the bend handle sits — handles win
        // over bodies, so testing there would prove nothing about the curve.
        let onCurve = body.curvePoint(at: 0.25)
        #expect(body.hitTest(onCurve, tolerance: 4, style: style) == .body)
        // The chord is where a naive straight-line test would look.
        #expect(body.hitTest(point(50, 0), tolerance: 4, style: style) == nil)
    }

    @Test("The bend handle takes precedence at the curve midpoint")
    func bendHandleWinsAtMidpoint() {
        let body = ArrowBody(start: point(0, 0), end: point(200, 0), bend: 0.4)
        let hit = body.hitTest(body.curvePoint(at: 0.5), tolerance: 4, style: style)
        #expect(hit == .handle(.bend))
    }
}

// MARK: - Editing

@Suite("Editing")
struct EditingTests {

    @Test("Dragging a corner keeps the opposite corner fixed")
    func resizeAnchorsOpposite() {
        let body = RectangleBody(rect: ImageRect(x: 10, y: 10, width: 100, height: 100))
        let edited = body.applying(
            HandleEdit(role: .corner(.topLeft), location: point(30, 40), constrain: false),
            style: style
        )
        #expect(edited.rect.maxX == ImagePx(110))
        #expect(edited.rect.maxY == ImagePx(110))
        #expect(edited.rect.minX == ImagePx(30))
    }

    @Test("Shift makes a resize square")
    func constrainedResize() {
        let body = RectangleBody(rect: ImageRect(x: 0, y: 0, width: 100, height: 100))
        let edited = body.applying(
            HandleEdit(role: .corner(.bottomRight), location: point(200, 40), constrain: true),
            style: style
        )
        #expect(edited.rect.width == edited.rect.height)
    }

    @Test("Translation moves every part of a shape together")
    func translation() {
        let arrow = ArrowBody(start: point(0, 0), end: point(50, 50))
        let moved = arrow.translated(by: ImageVector(dx: 10, dy: 20))
        #expect(moved.start == point(10, 20))
        #expect(moved.end == point(60, 70))
    }

    @Test("Editing is pure — the original is untouched")
    func editingIsPure() {
        // Undo is a snapshot of value types; a body that mutated in place would
        // corrupt the history silently.
        let body = RectangleBody(rect: ImageRect(x: 0, y: 0, width: 10, height: 10))
        _ = body.translated(by: ImageVector(dx: 100, dy: 100))
        _ = body.applying(
            HandleEdit(role: .corner(.topLeft), location: point(50, 50), constrain: false),
            style: style
        )
        #expect(body.rect == ImageRect(x: 0, y: 0, width: 10, height: 10))
    }

    @Test("Bending an arrow records a signed fraction, and zero is straight")
    func arrowBend() {
        let straight = ArrowBody(start: point(0, 0), end: point(100, 0))
        #expect(straight.curvePoint(at: 0.5) == point(50, 0))

        let bent = straight.applying(
            HandleEdit(role: .bend, location: point(50, 30), constrain: false), style: style
        )
        #expect(bent.bend != 0)
        #expect(bent.curvePoint(at: 0.5).y.value > 1)
    }
}

// MARK: - Ordering

@Suite("Z-order")
struct ZOrderTests {

    private func make(_ kind: Int) -> Annotation {
        Annotation(
            z: ZIndex(Double(kind)),
            style: style,
            body: .rectangle(RectangleBody(
                rect: ImageRect(
                    x: ImagePx(Double(kind) * 10), y: 0, width: 50, height: 50
                )
            ))
        )
    }

    @Test("Appending puts an object on top")
    func appendGoesOnTop() {
        var ordered = OrderedAnnotations()
        ordered.append(make(1))
        ordered.append(make(2))
        #expect(ordered.all.last?.bounds.minX == ImagePx(20))
    }

    @Test("Bring to front is one field write, not a renumber")
    func bringToFront() {
        var ordered = OrderedAnnotations()
        ordered.append(make(1))
        ordered.append(make(2))
        ordered.append(make(3))
        let bottom = ordered.all[0]
        ordered.bringToFront(bottom.id)
        #expect(ordered.all.last?.id == bottom.id)
    }

    @Test("Hit testing returns the topmost object")
    func topmostWins() {
        // Two overlapping rects: the one drawn last must be the one grabbed.
        var ordered = OrderedAnnotations()
        let lower = Annotation(
            z: ZIndex(0), style: style,
            body: .rectangle(RectangleBody(rect: ImageRect(x: 0, y: 0, width: 100, height: 100)))
        )
        let upper = Annotation(
            z: ZIndex(0), style: style,
            body: .rectangle(RectangleBody(rect: ImageRect(x: 0, y: 0, width: 100, height: 100)))
        )
        ordered.append(lower)
        ordered.append(upper)
        #expect(ordered.hitTest(point(0, 50), tolerance: 3)?.0.id == upper.id)
    }

    @Test("Renormalising collapses fractional depths to integers")
    func renormalise() {
        var ordered = OrderedAnnotations()
        ordered.append(make(1))
        ordered.append(make(2))
        ordered.renormalise()
        #expect(ordered.all.map(\.z.value) == [0, 1])
    }

    @Test("Counter numbering continues from the highest in use")
    func counterNumbering() {
        var ordered = OrderedAnnotations()
        #expect(ordered.nextCounterNumber == 1)
        ordered.append(Annotation(
            z: ZIndex(0), style: style,
            body: .counter(CounterBody(center: point(10, 10), number: 4))
        ))
        #expect(ordered.nextCounterNumber == 5)
    }
}

// MARK: - Serialization

@Suite("Serialization")
struct SerializationTests {

    @Test("Every body kind round-trips through Codable", arguments: sampleBodies)
    func roundTrip(_ body: AnyAnnotationBody) throws {
        let annotation = Annotation(z: ZIndex(3), style: style, body: body)
        let data = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(Annotation.self, from: data)
        #expect(decoded == annotation)
    }

    @Test("The kind discriminant survives encoding")
    func kindSurvives() throws {
        for body in sampleBodies {
            let data = try JSONEncoder().encode(body)
            let decoded = try JSONDecoder().decode(AnyAnnotationBody.self, from: data)
            #expect(decoded.kind == body.kind)
        }
    }
}

private let sampleBodies: [AnyAnnotationBody] = [
    .arrow(ArrowBody(start: point(0, 0), end: point(50, 50), bend: 0.3)),
    .line(LineBody(start: point(0, 0), end: point(10, 10))),
    .rectangle(RectangleBody(rect: ImageRect(x: 1, y: 2, width: 30, height: 40))),
    .oval(OvalBody(rect: ImageRect(x: 1, y: 2, width: 30, height: 40))),
    .text(TextBody(text: "hello", origin: point(5, 5), target: point(40, 40))),
    .freehand(FreehandBody(points: [point(0, 0), point(5, 5), point(10, 2)])),
    .highlighter(HighlighterBody(points: [point(0, 0), point(20, 0)])),
    .counter(CounterBody(center: point(30, 30), number: 2)),
    .conceal(ConcealBody(rect: ImageRect(x: 0, y: 0, width: 40, height: 20), mode: .pixelate)),
]

// MARK: - Freehand simplification

@Suite("Freehand")
struct FreehandTests {

    @Test("Simplification drops redundant collinear samples")
    func simplifyCollinear() {
        let points = (0...50).map { point(Double($0), 0) }
        let simplified = FreehandBody.simplified(points)
        // A straight line needs two points, however many were sampled.
        #expect(simplified.count == 2)
    }

    @Test("Simplification keeps the shape of a real curve")
    func simplifyKeepsShape() {
        let points = (0...50).map { index -> ImagePoint in
            let t = Double(index)
            return point(t, sin(t / 8) * 40)
        }
        let simplified = FreehandBody.simplified(points)
        #expect(simplified.count > 4)
        #expect(simplified.count < points.count)
        // Endpoints must be preserved exactly or the stroke visibly shifts.
        #expect(simplified.first == points.first)
        #expect(simplified.last == points.last)
    }

    @Test("Simplification leaves short strokes alone")
    func simplifyShort() {
        let points = [point(0, 0), point(5, 5)]
        #expect(FreehandBody.simplified(points).count == 2)
    }
}

// MARK: - Conceal

@Suite("Conceal")
struct ConcealTests {

    @Test("Only pixelate and solid are honestly irreversible")
    func reversibility() {
        // A small-radius Gaussian is partially invertible, which matters when
        // the whole point is hiding something before publishing.
        #expect(ConcealMode.pixelate.isIrreversible)
        #expect(ConcealMode.solid.isIrreversible)
        #expect(!ConcealMode.blur.isIrreversible)
    }

    @Test("A patch is produced and clipped to the image")
    func patchClipped() throws {
        let context = CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = context.makeImage()!

        let body = ConcealBody(rect: ImageRect(x: 80, y: 80, width: 60, height: 60))
        let patch = try #require(ConcealRenderer.patch(for: body, in: image))
        #expect(patch.rect.width <= 20)
        #expect(patch.rect.height <= 20)
    }
}
