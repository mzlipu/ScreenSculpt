// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import SSGeometry
import SSImaging
import Testing

@testable import SSEditorUI

/// What the canvas draws over the image while a selection exists.
///
/// Rendered off-screen through `cacheDisplay`, which runs the real `draw(_:)`
/// — the alternative is judging chrome by eye, and chrome is exactly the part
/// that silently stops appearing.
@MainActor
private func renderCanvas(
    selection: ImageRect?, size: NSSize = NSSize(width: 400, height: 300)
) -> NSBitmapImageRep {
    render(selection: selection, size: size).rep
}

/// The render plus where the selection landed, so a test can look at the rows
/// the readout occupies rather than guessing at them — the canvas centres a
/// fitted image, so image coordinates are nowhere near view coordinates.
@MainActor
private struct CanvasRender {
    let rep: NSBitmapImageRep
    let canvasRect: CGRect
    let scale: Int
}

@MainActor
private func render(
    selection: ImageRect?, size: NSSize = NSSize(width: 400, height: 300)
) -> CanvasRender {
    let context = CGContext(
        data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
    let image = RasterImage(cgImage: context.makeImage()!, pixelScale: .x2)

    let canvas = CanvasView(image: image)
    canvas.frame = NSRect(origin: .zero, size: size)
    canvas.zoomToFit()
    canvas.setSelection(selection)

    let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    let rect = selection.map { canvas.transform.toCanvas($0).cgRect } ?? .zero
    return CanvasRender(
        rep: rep, canvasRect: rect, scale: max(1, rep.pixelsHigh / Int(size.height))
    )
}

/// Counts near-white pixels, optionally within a band of rows.
///
/// White is the right thing to look for: the base image is a CALayer and
/// `cacheDisplay` does not render layers, so the backdrop of this render is
/// black and only the chrome — marquee, handles, readout text — is light.
private func lightPixelCount(_ rep: NSBitmapImageRep, rows: Range<Int>? = nil) -> Int {
    let range = rows ?? 0..<rep.pixelsHigh
    var count = 0
    for y in range.clamped(to: 0..<rep.pixelsHigh) {
        for x in 0..<rep.pixelsWide {
            guard let colour = rep.colorAt(x: x, y: y) else { continue }
            if colour.redComponent > 0.75, colour.greenComponent > 0.75,
               colour.blueComponent > 0.75, colour.alphaComponent > 0.5 {
                count += 1
            }
        }
    }
    return count
}

@Suite("Selection chrome")
@MainActor
struct SelectionChromeTests {

    /// The regression that matters: dragging out a crop region and being told
    /// nothing about its size.
    @Test("A selection draws a size readout")
    func drawsSizeReadout() {
        let none = lightPixelCount(renderCanvas(selection: nil))
        let some = lightPixelCount(renderCanvas(
            selection: ImageRect(x: 20, y: 20, width: 100, height: 60)
        ))
        #expect(none == 0, "nothing should be drawn without a selection")
        #expect(some > 0, "no chrome at all appeared for a selection")
    }

    /// The marquee alone would satisfy the test above. This looks specifically
    /// at the rows above the selection, where the readout goes and where the
    /// marquee does not reach.
    @Test("The readout appears above the selection, not just the marquee")
    func readoutIsPresent() {
        let shot = render(selection: ImageRect(x: 40, y: 60, width: 100, height: 60))
        // The band between the top of the view and the top of the marquee.
        // Nothing but the readout is drawn there.
        let top = Int(shot.canvasRect.minY) * shot.scale
        let band = max(0, top - 26 * shot.scale)..<max(1, top - 2 * shot.scale)
        #expect(
            lightPixelCount(shot.rep, rows: band) > 0,
            "no size readout was drawn above the selection (rows \(band))"
        )
    }

    /// A selection at the very top has no room above it for the label, which is
    /// where it normally goes.
    /// A selection at the very top has no room above it for the label, which is
    /// where it normally goes.
    @Test("The readout stays on screen for a selection at the top edge")
    func readoutAvoidsTopEdge() {
        let top = lightPixelCount(renderCanvas(
            selection: ImageRect(x: 10, y: 0, width: 120, height: 40)
        ))
        let middle = lightPixelCount(renderCanvas(
            selection: ImageRect(x: 10, y: 60, width: 120, height: 40)
        ))
        #expect(top > 0)
        // Comparable amounts of chrome: the label moved, it did not vanish.
        #expect(Double(top) > Double(middle) * 0.6, "top \(top) vs middle \(middle)")
    }
}

/// Renders the real layer tree — the view's own drawn content *and* its
/// sublayers, composited in the order the window server would.
///
/// `cacheDisplay` deliberately skips layers, which makes it useless for the one
/// question that matters here: whether the base image is drawn over the chrome.
@MainActor
private func renderLayerTree(selection: ImageRect?) -> NSBitmapImageRep {
    let source = CGContext(
        data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Mid grey: distinguishable from both the dark canvas ground and the white
    // chrome, so whichever ends up on top is obvious.
    source.setFillColor(CGColor(gray: 0.5, alpha: 1))
    source.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
    let image = RasterImage(cgImage: source.makeImage()!, pixelScale: .x2)

    let canvas = CanvasView(image: image)
    canvas.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    canvas.zoomToFit()
    canvas.setSelection(selection)
    canvas.layoutSubtreeIfNeeded()
    canvas.displayIfNeeded()

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    canvas.layer?.render(in: context.cgContext)
    return rep
}

@Suite("Selection chrome over the image")
@MainActor
struct ChromeLayerOrderTests {

    /// The question a headless `cacheDisplay` cannot answer: once the captured
    /// image is actually on screen, is the marquee still visible over it?
    @Test("The marquee is drawn above the captured image")
    func chromeIsNotBuriedByTheImage() {
        let plain = lightPixelCount(renderLayerTree(selection: nil))
        let marked = lightPixelCount(
            renderLayerTree(selection: ImageRect(x: 40, y: 40, width: 100, height: 60))
        )
        #expect(
            marked > plain,
            "the selection chrome is not visible over the image (\(plain) vs \(marked))"
        )
    }
}

@Suite("Selection readout")
@MainActor
struct SelectionReadoutTests {

    private func canvas(pixelScale: PixelScale) -> CanvasView {
        let context = CGContext(
            data: nil, width: 200, height: 150, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 150))
        let view = CanvasView(
            image: RasterImage(cgImage: context.makeImage()!, pixelScale: pixelScale)
        )
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.zoomToFit()
        return view
    }

    @Test("The readout states the size in pixels")
    func reportsPixels() {
        let view = canvas(pixelScale: .x1)
        let text = view.sizeLabelText(for: ImageRect(x: 0, y: 0, width: 120, height: 64))
        #expect(text == "120 × 64 px")
    }

    /// On a retina capture the points matter as much as the pixels — a designer
    /// asked for a 320pt column, not a 640px one.
    @Test("A retina capture also reports points")
    func reportsPointsOnRetina() {
        let view = canvas(pixelScale: .x2)
        let text = view.sizeLabelText(for: ImageRect(x: 0, y: 0, width: 640, height: 200))
        #expect(text.contains("640 × 200 px"))
        #expect(text.contains("320 × 100 pt"))
    }

    /// The case that prompted this: making a selection after a crop, when the
    /// canvas has been resized and refitted under the marquee.
    @Test("The readout still appears on a cropped canvas")
    func survivesACrop() {
        let view = canvas(pixelScale: .x2)

        // A crop replaces the image and refits the view, exactly as the editor
        // does after cropping.
        let cropped = CGContext(
            data: nil, width: 90, height: 70, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        cropped.setFillColor(CGColor(gray: 0.5, alpha: 1))
        cropped.fill(CGRect(x: 0, y: 0, width: 90, height: 70))
        view.update(
            image: RasterImage(cgImage: cropped.makeImage()!, pixelScale: .x2), selection: nil
        )
        view.setSelection(ImageRect(x: 10, y: 10, width: 50, height: 40))

        #expect(view.sizeLabelText(for: view.selection!) == "50 × 40 px   25 × 20 pt")

        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(lightPixelCount(rep) > 0, "no chrome drawn after a crop")
    }

    /// While dragging, the readout tracks the pointer instead of the corner the
    /// drag began at — which on a large screenshot is nowhere near the eye.
    @Test("The readout follows the pointer during a drag")
    func followsThePointer() {
        let view = canvas(pixelScale: .x2)
        view.setSelection(ImageRect(x: 10, y: 10, width: 150, height: 120))

        func render() -> NSBitmapImageRep {
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }

        view.isDraggingSelection = true
        view.selectionCursor = ImagePoint(x: ImagePx(160), y: ImagePx(130))
        let nearCursor = render()

        view.isDraggingSelection = false
        view.selectionCursor = nil
        let atCorner = render()

        // Same content, different place: the light pixels must not coincide.
        var differing = 0
        for y in 0..<nearCursor.pixelsHigh where differing == 0 {
            for x in 0..<nearCursor.pixelsWide
            where nearCursor.colorAt(x: x, y: y) != atCorner.colorAt(x: x, y: y) {
                differing += 1
                break
            }
        }
        #expect(differing > 0, "the readout did not move with the pointer")
    }
}
