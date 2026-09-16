// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSAnnotations
import SSDocument
import SSGeometry
import SSImaging
import Testing

@testable import SSRender

/// A plain white canvas, so any drawn pixel is unambiguous.
private func makeBase(width: Int = 200, height: Int = 200) -> RasterImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)
}

/// A base with strong structure, so a blur has something to destroy.
private func makeStripedBase(width: Int = 200, height: Int = 200) -> RasterImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    for x in stride(from: 0, to: width, by: 4) {
        context.setFillColor(
            (x / 4) % 2 == 0
                ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        context.fill(CGRect(x: x, y: 0, width: 4, height: height))
    }
    return RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)
}

private func rawPixels(_ image: RasterImage) -> [UInt8] {
    let width = image.cgImage.width
    let height = image.cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(
            data: buffer.baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(
            image.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }
    return bytes
}

/// How many bytes differ between two renders.
private func changedBytes(_ a: RasterImage, _ b: RasterImage) -> Int {
    let left = rawPixels(a), right = rawPixels(b)
    guard left.count == right.count else { return .max }
    return zip(left, right).reduce(into: 0) { total, pair in
        if pair.0 != pair.1 { total += 1 }
    }
}

nonisolated private func point(_ x: Double, _ y: Double) -> ImagePoint {
    ImagePoint(x: ImagePx(x), y: ImagePx(y))
}

nonisolated private let style = AnnotationStyle(color: .red, strokeWidth: 6, fontSize: 24)

/// One representative instance of every tool, drawn across the same area.
nonisolated private func everyBody() -> [(AnnotationKind, AnyAnnotationBody)] {
    let stroke = [point(20, 20), point(60, 90), point(120, 40), point(170, 150)]
    return [
        (.arrow, .arrow(ArrowBody(start: point(20, 20), end: point(170, 170)))),
        (.line, .line(LineBody(start: point(20, 100), end: point(180, 100)))),
        (.rectangle, .rectangle(RectangleBody(
            rect: ImageRect(x: 30, y: 30, width: 120, height: 90)
        ))),
        (.oval, .oval(OvalBody(rect: ImageRect(x: 30, y: 30, width: 120, height: 90)))),
        (.text, .text(TextBody(text: "Hello", origin: point(30, 60)))),
        (.freehand, .freehand(FreehandBody(points: stroke))),
        (.highlighter, .highlighter(HighlighterBody(points: stroke))),
        (.counter, .counter(CounterBody(center: point(100, 100), number: 3))),
        (.conceal, .conceal(ConcealBody(
            rect: ImageRect(x: 40, y: 40, width: 100, height: 100), mode: .pixelate
        ))),
        (.spotlight, .spotlight(SpotlightBody(
            rect: ImageRect(x: 60, y: 60, width: 80, height: 80)
        ))),
        (.magnifier, .magnifier(MagnifierBody(
            rect: ImageRect(x: 40, y: 40, width: 100, height: 100)
        ))),
        (.ruler, .ruler(RulerBody(start: point(20, 100), end: point(180, 130)))),
        (.imageOverlay, .imageOverlay(swatchOverlay())),
    ]
}

/// A small solid image, encoded the way a placed overlay stores its bytes.
nonisolated private func swatchOverlay() -> ImageOverlayBody {
    let context = CGContext(
        data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    return ImageOverlayBody.make(
        from: context.makeImage()!, at: ImageRect(x: 40, y: 40, width: 100, height: 75)
    )!
}

@Suite("Flatten renders every tool")
@MainActor
struct FlattenTests {

    /// Guards the fixture itself. Both tests below iterate a hand-written list,
    /// so a tool left out of it is a tool with no rendering coverage at all —
    /// and that omission looks exactly like passing.
    @Test("The fixture covers every tool that exists")
    func fixtureIsComplete() {
        let covered = Set(everyBody().map(\.0))
        let missing = AnnotationKind.allCases.filter { !covered.contains($0) }
        #expect(missing.isEmpty, "no render coverage for \(missing.map(\.label))")
    }

    /// The regression this whole file exists for: a tool that silently draws
    /// nothing looks exactly like a tool that works, until someone tries it.
    @Test("Every tool changes pixels when flattened", arguments: everyBody())
    func toolDrawsSomething(_ entry: (kind: AnnotationKind, body: AnyAnnotationBody)) {
        let base = entry.kind == .conceal ? makeStripedBase() : makeBase()
        let store = DocumentStore(image: base)
        store.add(entry.body, style: style)

        let flattened = AnnotationRenderer.flatten(store.document)
        let changed = changedBytes(base, flattened)

        #expect(changed > 200, "\(entry.kind.label) drew \(changed) changed bytes")
    }

    /// The editor preview uses `isExport: false`, a different code path from
    /// flatten. A tool can render correctly in a saved file and still show
    /// nothing on screen.
    @Test("Every tool also draws in the on-screen path", arguments: everyBody())
    func toolDrawsOnScreen(_ entry: (kind: AnnotationKind, body: AnyAnnotationBody)) {
        let base = entry.kind == .conceal ? makeStripedBase() : makeBase()
        let store = DocumentStore(image: base)
        store.add(entry.body, style: style)

        let width = base.size.pixelWidth, height = base.size.pixelHeight
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(base.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        AnnotationRenderer.draw(
            store.annotations,
            baseImage: base.cgImage,
            in: context,
            render: RenderContext(
                pixelScale: .x1, isExport: false,
                imageBounds: ImageRect(
                    x: .zero, y: .zero,
                    width: ImagePx(Double(width)), height: ImagePx(Double(height))
                )
            )
        )

        let rendered = RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)
        let changed = changedBytes(base, rendered)
        #expect(changed > 200, "\(entry.kind.label) drew \(changed) changed bytes on screen")
    }

    /// The live canvas concatenates a zoom/pan transform before drawing, which
    /// none of the other render tests do. Conceal is the tool most exposed to
    /// that, because it flips the context locally to draw its patch.
    @Test("Conceal still draws under a canvas transform", arguments: [0.5, 1.0, 3.0])
    func concealUnderTransform(_ zoom: Double) {
        let base = makeStripedBase()
        let store = DocumentStore(image: base)
        store.add(
            .conceal(ConcealBody(
                rect: ImageRect(x: 40, y: 40, width: 100, height: 100), mode: .pixelate
            )),
            style: style
        )

        let width = 400, height = 400
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let transform = CanvasTransform(
            zoom: zoom, imageOrigin: ImagePoint(x: 5, y: 7), backingScale: .x1
        )
        context.concatenate(transform.cgAffine)

        let before = context.makeImage()!
        AnnotationRenderer.draw(
            store.annotations,
            baseImage: base.cgImage,
            in: context,
            render: RenderContext(pixelScale: .x1, isExport: true)
        )
        let after = context.makeImage()!

        let changed = changedBytes(
            RasterImage(cgImage: before, pixelScale: .x1),
            RasterImage(cgImage: after, pixelScale: .x1)
        )
        #expect(changed > 200, "conceal drew \(changed) changed bytes at zoom \(zoom)")
    }

    @Test("Flattening an empty document returns the original untouched")
    func emptyIsIdentity() {
        let base = makeBase()
        let store = DocumentStore(image: base)
        #expect(changedBytes(base, AnnotationRenderer.flatten(store.document)) == 0)
    }

    @Test("Flatten preserves pixel dimensions and scale")
    func preservesGeometry() {
        let base = makeBase(width: 321, height: 123)
        let store = DocumentStore(image: base)
        store.add(
            .rectangle(RectangleBody(rect: ImageRect(x: 10, y: 10, width: 50, height: 50))),
            style: style
        )
        let flattened = AnnotationRenderer.flatten(store.document)
        #expect(flattened.size == base.size)
        #expect(flattened.pixelScale == base.pixelScale)
    }

    @Test("Annotations composite in z-order")
    func zOrderRespected() {
        // A filled white rect over a filled black one must leave white on top.
        var opaque = style
        opaque.fill = .opaque

        let store = DocumentStore(image: makeBase())
        var black = opaque
        black.color = .black
        var white = opaque
        white.color = .white

        store.add(
            .rectangle(RectangleBody(rect: ImageRect(x: 20, y: 20, width: 160, height: 160))),
            style: black
        )
        store.add(
            .rectangle(RectangleBody(rect: ImageRect(x: 60, y: 60, width: 80, height: 80))),
            style: white
        )

        let flattened = AnnotationRenderer.flatten(store.document)
        let pixel = flattened.pixelColor(at: point(100, 100))
        #expect(pixel?.r ?? 0 > 200, "the later rectangle should be on top")
    }
}

@Suite("Body bounds")
struct BoundsTests {

    /// Bounds drive invalidation *and* the degenerate-object check that discards
    /// an accidental click. A multi-point body reporting a zero-size box gets
    /// deleted the instant it is drawn.
    @Test("A multi-point stroke reports the box that contains every point")
    func freehandBoundsSpanAllPoints() {
        let body = FreehandBody(points: [
            point(10, 20), point(100, 5), point(60, 140),
        ])
        #expect(body.bounds.minX == ImagePx(10))
        #expect(body.bounds.minY == ImagePx(5))
        #expect(body.bounds.maxX == ImagePx(100))
        #expect(body.bounds.maxY == ImagePx(140))
        #expect(!body.bounds.isEmpty)
    }

    @Test("Highlighter bounds span every point too")
    func highlighterBounds() {
        let body = HighlighterBody(points: [point(0, 0), point(80, 30)])
        #expect(body.bounds.width == ImagePx(80))
        #expect(body.bounds.height == ImagePx(30))
    }

    @Test("A single-point stroke is still empty, and stays discardable")
    func singlePointIsEmpty() {
        #expect(FreehandBody(points: [point(5, 5)]).bounds.isEmpty)
        #expect(FreehandBody(points: []).bounds.isEmpty)
    }

    @Test("A text body has a real box even before anything is typed")
    func emptyTextHasBox() {
        // Otherwise a freshly placed label is discarded as degenerate before
        // the user can type into it.
        let body = TextBody(text: "", origin: point(10, 10))
        #expect(body.bounds.width.value > 3)
        #expect(body.bounds.height.value > 3)
    }
}

// MARK: - Blur versus Flatten

/// These two are routinely confused because after clicking Flatten the picture
/// looks *identical*. That is correct — flatten changes the document's
/// structure, not its appearance — but it makes the button feel broken.
@Suite("Blur versus flatten")
@MainActor
struct BlurVersusFlattenTests {

    @Test("Blur adds an object; the raster is untouched")
    func blurIsNonDestructive() {
        let base = makeStripedBase()
        let store = DocumentStore(image: base)
        store.add(
            .conceal(ConcealBody(rect: ImageRect(x: 40, y: 40, width: 100, height: 100))),
            style: style
        )

        #expect(store.annotations.count == 1)
        // The pixels underneath are still there, which is why a blur can be
        // moved afterwards — and why an unflattened document still contains
        // whatever it is hiding.
        #expect(changedBytes(base, store.raster) == 0)
    }

    @Test("Flatten bakes objects into the raster and removes them")
    func flattenIsDestructive() {
        let base = makeStripedBase()
        let store = DocumentStore(image: base)
        store.add(
            .conceal(ConcealBody(rect: ImageRect(x: 40, y: 40, width: 100, height: 100))),
            style: style
        )

        store.flatten(using: AnnotationRenderer.flatten(store.document))

        #expect(store.annotations.isEmpty, "objects are consumed")
        #expect(changedBytes(base, store.raster) > 200, "pixels are now changed")
    }

    @Test("Flatten changes nothing on screen — which is why it looks like a no-op")
    func flattenIsVisuallyIdentical() {
        let store = DocumentStore(image: makeStripedBase())
        store.add(
            .conceal(ConcealBody(rect: ImageRect(x: 40, y: 40, width: 100, height: 100))),
            style: style
        )

        let before = AnnotationRenderer.flatten(store.document)
        store.flatten(using: before)
        let after = AnnotationRenderer.flatten(store.document)

        #expect(changedBytes(before, after) == 0)
    }

    @Test("Flatten is undoable, unlike most implementations of it")
    func flattenUndoes() {
        let store = DocumentStore(image: makeStripedBase())
        store.add(
            .conceal(ConcealBody(rect: ImageRect(x: 40, y: 40, width: 100, height: 100))),
            style: style
        )
        store.flatten(using: AnnotationRenderer.flatten(store.document))
        #expect(store.annotations.isEmpty)

        store.undo()
        #expect(store.annotations.count == 1, "the object should come back")
    }

    @Test("Flatten on a document with no objects does nothing at all")
    func flattenNoOp() {
        let store = DocumentStore(image: makeStripedBase())
        store.flatten(using: makeBase())
        #expect(!store.canUndo, "an empty flatten should not create an undo step")
    }
}
