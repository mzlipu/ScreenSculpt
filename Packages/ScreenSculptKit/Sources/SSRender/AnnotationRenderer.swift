// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import ImageIO
import SSAnnotations
import SSDocument
import SSGeometry
import SSImaging
import SSRecognition

/// Draws annotations, on screen and for export.
///
/// One implementation for both, differing only by `RenderContext.isExport`.
/// That is deliberate: a separate export path is how editors end up with a
/// saved file that does not match what the user was looking at.
public enum AnnotationRenderer {

    /// Draw every annotation into a context whose CTM is already image-pixel
    /// space.
    ///
    /// `baseImage` is needed because conceal bodies operate on the pixels
    /// underneath them — a body never sees the document, so the renderer
    /// resolves that here.
    public static func draw(
        _ annotations: OrderedAnnotations,
        baseImage: CGImage?,
        in context: CGContext,
        render: RenderContext,
        skipping excluded: Set<AnnotationID> = []
    ) {
        for annotation in annotations.all where !excluded.contains(annotation.id) {
            context.saveGState()

            // Three kinds need pixels a body never sees: a blur reads what is
            // underneath, a magnifier repeats it larger, and an overlay carries
            // encoded bytes too costly to decode in a draw call. Each is drawn
            // here first, then the body adds its own outline on top.
            if let conceal = annotation.body.concealBody, let baseImage {
                drawConceal(conceal, baseImage: baseImage, in: context)
            } else if let magnifier = annotation.body.magnifierBody, let baseImage {
                drawMagnifier(magnifier, baseImage: baseImage, in: context)
            } else if let overlay = annotation.body.imageOverlayBody {
                drawOverlay(overlay, opacity: annotation.style.opacity, in: context)
            }
            annotation.body.draw(in: context, style: annotation.style, render: render)

            context.restoreGState()
        }
    }

    /// Enlarge the region under a loupe.
    private static func drawMagnifier(
        _ body: MagnifierBody, baseImage: CGImage, in context: CGContext
    ) {
        guard let patch = MagnifierRenderer.patch(for: body, in: baseImage) else { return }
        context.saveGState()
        // Clipped to the lens, so the enlargement cannot spill past its rim.
        if patch.isCircular {
            context.addEllipse(in: patch.rect)
        } else {
            context.addPath(CGPath(
                roundedRect: patch.rect, cornerWidth: 6, cornerHeight: 6, transform: nil
            ))
        }
        context.clip()
        // The context is y-down relative to CGImage, so un-flip locally rather
        // than globally — a global flip would invert every later annotation.
        context.translateBy(x: 0, y: patch.rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(patch.image, in: patch.rect)
        context.restoreGState()
    }

    /// Draw a placed image, decoding through a cache.
    private static func drawOverlay(
        _ body: ImageOverlayBody, opacity: Double, in context: CGContext
    ) {
        guard let image = OverlayImageCache.image(for: body.data) else { return }
        let rect = body.rect.cgRect
        context.saveGState()
        context.setAlpha(CGFloat(opacity))
        context.translateBy(x: 0, y: rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    private static func drawConceal(
        _ body: ConcealBody, baseImage: CGImage, in context: CGContext
    ) {
        if body.mode.isTextTargeted {
            drawTextOnlyConceal(body, baseImage: baseImage, in: context)
            return
        }
        guard let patch = ConcealRenderer.patch(for: body, in: baseImage) else { return }
        // The context is flipped relative to CGImage's coordinate system, so
        // un-flip locally rather than globally — flipping the whole context
        // would invert every annotation drawn after this one.
        context.saveGState()
        context.translateBy(x: 0, y: patch.rect.midY * 2)
        context.scaleBy(x: 1, y: -1)
        context.draw(patch.image, in: patch.rect)
        context.restoreGState()
    }

    /// Cover only the words inside the region.
    ///
    /// The detected rects are cached per (image, region) because recognition
    /// costs tens of milliseconds and the renderer runs on every redraw — doing
    /// it inline would make dragging a text-only blur unusable.
    private static func drawTextOnlyConceal(
        _ body: ConcealBody, baseImage: CGImage, in context: CGContext
    ) {
        let regions = TextRegionCache.regions(for: body.rect, in: baseImage)
        for region in regions {
            var word = body
            word.rect = region
            word.mode = .pixelate
            guard let patch = ConcealRenderer.patch(for: word, in: baseImage) else { continue }
            context.saveGState()
            context.translateBy(x: 0, y: patch.rect.midY * 2)
            context.scaleBy(x: 1, y: -1)
            context.draw(patch.image, in: patch.rect)
            context.restoreGState()
        }
    }

    /// Composite the raster and every annotation into one image.
    ///
    /// This is what export, copy and drag-out all use, so what lands in a file
    /// cannot drift from what the canvas showed.
    public static func flatten(_ document: ShotDocument) -> RasterImage {
        let base = document.render()
        guard !document.annotations.isEmpty else { return base }

        let width = base.size.pixelWidth
        let height = base.size.pixelHeight
        guard
            width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: base.cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return base }

        context.draw(
            base.cgImage, in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        // Flip into image-pixel space: origin top-left, Y down, which is what
        // every body's geometry assumes.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        draw(
            document.annotations,
            baseImage: base.cgImage,
            in: context,
            render: RenderContext(
                pixelScale: base.pixelScale, isExport: true,
                imageBounds: ImageRect(
                    x: .zero, y: .zero,
                    width: ImagePx(Double(width)), height: ImagePx(Double(height))
                )
            )
        )

        guard let output = context.makeImage() else { return base }
        return RasterImage(cgImage: output, pixelScale: base.pixelScale)
    }
}

/// Decoded overlay images, kept between draws.
///
/// Decoding a PNG costs milliseconds and `draw` runs on every redraw, so
/// without this, dragging an overlay would decode it once per frame.
@MainActor
enum OverlayImageCache {

    private static var cache: [Int: CGImage] = [:]

    static func image(for data: Data) -> CGImage? {
        let key = data.hashValue
        if let cached = cache[key] { return cached }
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        // Bounded, or a long session placing many overlays grows without limit.
        if cache.count > 32 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// Memoises detected text regions.
///
/// Recognition is far too slow to run inside a draw call, and the answer only
/// changes when the image or the region does.
@MainActor
enum TextRegionCache {

    private struct Key: Hashable {
        let image: ObjectIdentifier
        let rect: ImageRect
    }

    private static var cache: [Key: [ImageRect]] = [:]

    static func regions(for rect: ImageRect, in image: CGImage) -> [ImageRect] {
        let key = Key(image: ObjectIdentifier(image), rect: rect)
        if let cached = cache[key] { return cached }

        let found = TextRegionMasker.textRegions(
            in: RasterImage(cgImage: image, pixelScale: .x1), within: rect
        )
        // Bounded, because a long session with many edits would otherwise grow
        // this without limit.
        if cache.count > 64 { cache.removeAll() }
        cache[key] = found
        return found
    }
}
