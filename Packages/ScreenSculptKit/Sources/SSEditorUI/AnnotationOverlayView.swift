// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSAnnotations
import SSDocument
import SSGeometry
import SSImaging
import SSRender

/// Draws annotations above the raster layer and below the chrome.
///
/// Sits between `baseLayer` and the selection chrome, which is the gap the
/// canvas was structured around from the start. Annotation geometry is in image
/// pixels, so this view concatenates the canvas transform once and every body
/// then draws in its own coordinate space, knowing nothing about zoom.
@MainActor
final class AnnotationOverlayView: NSView {

    var transform: CanvasTransform = .identity()
    var annotations = OrderedAnnotations()
    var baseImage: CGImage?
    var pixelScale: PixelScale = .x2

    /// The object currently being dragged, excluded here and drawn by the scrim
    /// instead, so this view's backing store is not invalidated during a drag.
    var suppressed: AnnotationID?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // events belong to the canvas

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard !annotations.isEmpty else { return }

        context.saveGState()
        context.concatenate(transform.cgAffine)

        AnnotationRendererBridge.draw(
            annotations,
            baseImage: baseImage,
            in: context,
            pixelScale: pixelScale,
            imageBounds: baseImage.imageBounds,
            skipping: suppressed.map { [$0] } ?? []
        )

        context.restoreGState()
    }
}

/// Transient top layer holding only the object under the cursor.
///
/// The point of this is performance: while dragging, the main overlay is never
/// invalidated, so Core Animation simply re-composites it and the per-frame cost
/// is proportional to the *dragged* object rather than to every object on the
/// canvas.
@MainActor
final class DragScrimView: NSView {

    var transform: CanvasTransform = .identity()
    var annotation: Annotation?
    var baseImage: CGImage?
    var pixelScale: PixelScale = .x2

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let annotation,
            let context = NSGraphicsContext.current?.cgContext
        else { return }

        context.saveGState()
        context.concatenate(transform.cgAffine)

        var single = OrderedAnnotations()
        single.append(annotation)
        AnnotationRendererBridge.draw(
            single, baseImage: baseImage, in: context, pixelScale: pixelScale,
            imageBounds: baseImage.imageBounds
        )

        context.restoreGState()
    }
}

/// Thin seam so the views do not each need to construct a `RenderContext`.
private enum AnnotationRendererBridge {
    static func draw(
        _ annotations: OrderedAnnotations,
        baseImage: CGImage?,
        in context: CGContext,
        pixelScale: PixelScale,
        imageBounds: ImageRect,
        skipping excluded: Set<AnnotationID> = []
    ) {
        AnnotationRenderer.draw(
            annotations,
            baseImage: baseImage,
            in: context,
            render: RenderContext(
                pixelScale: pixelScale, isExport: false, imageBounds: imageBounds
            ),
            skipping: excluded
        )
    }
}

extension Optional where Wrapped == CGImage {
    /// The canvas extent, which a spotlight needs to know how far to dim.
    var imageBounds: ImageRect {
        guard let self else { return .zero }
        return ImageRect(
            x: .zero, y: .zero,
            width: ImagePx(Double(self.width)), height: ImagePx(Double(self.height))
        )
    }
}
