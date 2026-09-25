// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit

/// The topmost layer of the canvas: marquee, handles, pixel grid, snap guides
/// and the size readout.
///
/// A separate view because it has to be *above* the captured image, and the
/// image is a sublayer of the canvas. Core Animation composites a layer's
/// sublayers above that layer's own drawn content, so chrome painted by
/// `CanvasView.draw(_:)` ends up behind the screenshot — present in the render
/// tree, invisible on screen, and impossible to notice in a headless test that
/// never composites the layer at all.
///
/// It draws nothing of its own and owns no state; everything comes from the
/// canvas, which stays the single source of truth for the transform and the
/// selection.
final class ChromeOverlayView: NSView {

    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }

    /// Events belong to the canvas underneath. Without this the overlay would
    /// swallow every click on the image.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard
            let canvas,
            let context = NSGraphicsContext.current?.cgContext
        else { return }
        canvas.drawChrome(in: context)
    }
}
