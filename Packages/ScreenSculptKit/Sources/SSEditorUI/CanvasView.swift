// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSDocument
import SSGeometry
import SSImaging

/// The editor canvas.
///
/// Structure follows the plan's three-layer design:
///
///   * `baseLayer` — a `CALayer` holding the raster. Zoom and pan are a layer
///     transform, so panning a 6000px capture costs no CPU redraw at all.
///   * this view's `draw(_:)` — chrome only (marquee, handles, pixel grid),
///     drawn in **view points** so it never scales with zoom.
///
/// Annotations will get their own view between the two when they land; keeping
/// chrome separate from content is what makes that addition non-invasive.
@MainActor
final class CanvasView: NSView {

    var onSelectionChanged: ((ImageRect?) -> Void)?
    var onTransformChanged: ((CanvasTransform) -> Void)?
    var onCommitCrop: (() -> Void)?

    private(set) var transform: CanvasTransform
    var image: RasterImage
    var selection: ImageRect?

    private let baseLayer = CALayer()

    var anchor: ImagePoint?
    var isDraggingSelection = false
    var isPanning = false
    var panOrigin: (mouse: NSPoint, imageOrigin: ImagePoint)?
    var spaceHeld = false

    /// Hit slop and handle size live in view points, so they feel identical at
    /// 25% and at 3200%.
    static let handleSide: CGFloat = 9

    init(image: RasterImage) {
        self.image = image
        transform = CanvasTransform(
            zoom: 1, imageOrigin: .zero, backingScale: PixelScale(2)
        )
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor

        baseLayer.contents = image.cgImage
        baseLayer.anchorPoint = .zero
        baseLayer.masksToBounds = false
        // Without this the layer animates every pan step and the image lags the
        // cursor.
        baseLayer.actions = [
            "position": NSNull(), "bounds": NSNull(),
            "contents": NSNull(), "transform": NSNull(),
        ]
        layer?.addSublayer(baseLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Content

    func update(image newImage: RasterImage, selection newSelection: ImageRect?) {
        let sizeChanged = newImage.size != image.size
        image = newImage
        selection = newSelection
        baseLayer.contents = newImage.cgImage
        if sizeChanged { zoomToFit() } else { layoutBase() }
        needsDisplay = true
    }

    func setSelection(_ rect: ImageRect?) {
        selection = rect
        needsDisplay = true
    }

    // MARK: - Backing scale

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncBackingScale()
        zoomToFit()
        window?.makeFirstResponder(self)
    }

    /// Dragging the window between a 2× and a 1× display changes the backing
    /// scale. Missing this is the classic "chrome goes blurry on the external
    /// monitor" bug — and this machine has exactly that arrangement.
    func syncBackingScale() {
        guard let scale = window?.backingScaleFactor else { return }
        let updated = transform.with(backingScale: PixelScale(Double(scale)))
        guard updated != transform else { return }
        transform = updated
        baseLayer.contentsScale = scale
        layoutBase()
        needsDisplay = true
        onTransformChanged?(transform)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutBase()
        needsDisplay = true
    }

    // MARK: - Zoom and pan

    func zoomToFit() {
        let zoom = CanvasTransform.fitZoom(
            image: image.size,
            viewport: CanvasSize(width: ViewPt(bounds.width), height: ViewPt(bounds.height)),
            backingScale: transform.backingScale
        )
        setTransform(centred(zoom: zoom))
    }

    func zoomToActualSize() { zoomAboutCentre(to: 1) }

    func zoomIn() { zoomAboutCentre(to: transform.nextZoomStop(increasing: true)) }
    func zoomOut() { zoomAboutCentre(to: transform.nextZoomStop(increasing: false)) }

    func zoomToSelection() {
        guard let selection, !selection.isEmpty else { return }
        let padding: Double = 40
        let zoomX = (Double(bounds.width) - padding) / selection.width.value
        let zoomY = (Double(bounds.height) - padding) / selection.height.value
        let zoom = min(zoomX, zoomY) * transform.backingScale.value
        var next = transform.with(zoom: zoom)
        let viewCentre = CanvasPoint(
            x: ViewPt(Double(bounds.width) / 2), y: ViewPt(Double(bounds.height) / 2)
        )
        let target = next.toImage(viewCentre)
        next = next.with(imageOrigin: ImagePoint(
            x: next.imageOrigin.x + (selection.center.x - target.x),
            y: next.imageOrigin.y + (selection.center.y - target.y)
        ))
        setTransform(next)
    }

    private func zoomAboutCentre(to zoom: Double) {
        let centre = CanvasPoint(
            x: ViewPt(Double(bounds.width) / 2), y: ViewPt(Double(bounds.height) / 2)
        )
        setTransform(transform.zoomed(to: zoom, anchoredAt: centre))
    }

    private func centred(zoom: Double) -> CanvasTransform {
        let candidate = transform.with(zoom: zoom)
        let visible = candidate.toImage(CanvasRect(
            x: 0, y: 0, width: ViewPt(bounds.width), height: ViewPt(bounds.height)
        ))
        return candidate.with(imageOrigin: ImagePoint(
            x: ImagePx((image.size.width.value - visible.width.value) / 2),
            y: ImagePx((image.size.height.value - visible.height.value) / 2)
        ))
    }

    func setTransform(_ next: CanvasTransform) {
        // Snap the pan offset to whole device pixels, or nearest-neighbour
        // magnification shimmers at high zoom.
        transform = next.snappedToDevicePixels()
        layoutBase()
        needsDisplay = true
        onTransformChanged?(transform)
    }

    private func layoutBase() {
        let origin = transform.toCanvas(ImagePoint.zero)
        let corner = transform.toCanvas(
            ImagePoint(x: image.size.width, y: image.size.height)
        )
        baseLayer.frame = CGRect(
            x: origin.x.cgFloat, y: origin.y.cgFloat,
            width: (corner.x - origin.x).cgFloat,
            height: (corner.y - origin.y).cgFloat
        )
        // Above 1:1, show the pixels rather than a smoothed lie about them.
        baseLayer.magnificationFilter = transform.usesNearestNeighbour ? .nearest : .trilinear
        baseLayer.minificationFilter = .trilinear
    }
}
