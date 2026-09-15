// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSAnnotations
import SSDocument
import SSGeometry
import SSImaging

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

            if let conceal = annotation.body.concealBody, let baseImage {
                drawConceal(conceal, baseImage: baseImage, in: context)
                // Still draw the body so the dashed editing outline appears on
                // screen; it suppresses itself on export.
                annotation.body.draw(
                    in: context, style: annotation.style, render: render
                )
            } else {
                annotation.body.draw(
                    in: context, style: annotation.style, render: render
                )
            }

            context.restoreGState()
        }
    }

    private static func drawConceal(
        _ body: ConcealBody, baseImage: CGImage, in context: CGContext
    ) {
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
            render: RenderContext(pixelScale: base.pixelScale, isExport: true)
        )

        guard let output = context.makeImage() else { return base }
        return RasterImage(cgImage: output, pixelScale: base.pixelScale)
    }
}
