// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSDocument
import SSGeometry
import SSImaging

/// The editor window: one capture, a canvas, and a toolbar.
///
/// Opens on the display the capture came from, which is what people expect and
/// is the reason `CaptureProvenance` records the source display at all.
@MainActor
public final class EditorWindowController: NSWindowController, NSWindowDelegate {

    public var onCopy: ((RasterImage) -> Void)?
    public var onSave: ((RasterImage) -> Void)?
    public var onClose: (() -> Void)?

    private let store: DocumentStore
    private let canvas: CanvasView
    private var zoomLabel: NSToolbarItem?
    private var statusField: NSTextField?

    public init(image: RasterImage, measurementUnavailable: Bool = false, onScreen: NSScreen?) {
        store = DocumentStore(image: image, measurementUnavailable: measurementUnavailable)
        canvas = CanvasView(image: image)

        let screen = onScreen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let target = Self.initialFrame(for: image, within: visible)

        let window = NSWindow(
            contentRect: target,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Screenshot"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.tabbingMode = .disallowed

        super.init(window: window)

        window.delegate = self
        installToolbar()
        wireCanvas()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fit the capture on screen without magnifying a small one.
    private static func initialFrame(for image: RasterImage, within visible: NSRect) -> NSRect {
        let points = image.logicalSize
        let width = min(points.width.cgFloat + 2, visible.width * 0.9)
        let height = min(points.height.cgFloat + 60, visible.height * 0.9)
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: max(width, 520),
            height: max(height, 380)
        )
    }

    private func wireCanvas() {
        canvas.onSelectionChanged = { [weak self] rect in
            self?.store.setSelection(rect)
            self?.updateStatus()
        }
        canvas.onTransformChanged = { [weak self] _ in self?.updateStatus() }
        canvas.onCommitCrop = { [weak self] in self?.cropToSelection() }
    }

    private func refresh() {
        canvas.update(image: store.raster, selection: store.document.selection)
        updateStatus()
    }

    // MARK: - Window

    public func windowDidChangeBackingProperties(_ notification: Notification) {
        // Moving between a 2x and 1x display changes the backing scale; without
        // this the chrome renders blurry on the other monitor.
        canvas.syncBackingScale()
    }

    public func windowWillClose(_ notification: Notification) { onClose?() }

    // MARK: - Actions

    @objc public func copyImage() { onCopy?(store.raster) }
    @objc public func saveImage() { onSave?(store.raster) }

    @objc public func cropToSelection() {
        store.cropToSelection()
        refresh()
    }

    @objc public func resetCrop() {
        store.resetCrop()
        refresh()
    }

    @objc public func undo() { store.undo(); refresh() }
    @objc public func redo() { store.redo(); refresh() }

    @objc public func zoomIn() { canvas.zoomIn() }
    @objc public func zoomOut() { canvas.zoomOut() }
    @objc public func zoomToFit() { canvas.zoomToFit() }
    @objc public func zoomToActualSize() { canvas.zoomToActualSize() }
    @objc public func zoomToSelection() { canvas.zoomToSelection() }

    // MARK: - Toolbar

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar

        let status = NSTextField(labelWithString: "")
        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        statusField = status
    }

    private func updateStatus() {
        let size = store.size
        let scale = store.pixelScale
        var parts = ["\(Int(size.width.value)) × \(Int(size.height.value)) px"]
        if scale.isRetina {
            parts.append("\(Int(size.width.inPoints(scale).value)) × "
                + "\(Int(size.height.inPoints(scale).value)) pt")
        }
        parts.append("\(Int((canvas.transform.zoom * 100).rounded()))%")
        if store.document.measurementUnavailable {
            // Honest about it rather than printing a number that is wrong for
            // half the image.
            parts.append("mixed-scale capture — measurements unavailable")
        }
        window?.subtitle = parts.joined(separator: "   ")
    }
}

// MARK: - Toolbar items

extension EditorWindowController: NSToolbarDelegate {

    private enum Item {
        static let copy = NSToolbarItem.Identifier("copy")
        static let save = NSToolbarItem.Identifier("save")
        static let crop = NSToolbarItem.Identifier("crop")
        static let reset = NSToolbarItem.Identifier("reset")
        static let zoomOut = NSToolbarItem.Identifier("zoomOut")
        static let zoomFit = NSToolbarItem.Identifier("zoomFit")
        static let zoomIn = NSToolbarItem.Identifier("zoomIn")
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Item.crop, Item.reset, .flexibleSpace,
            Item.zoomOut, Item.zoomFit, Item.zoomIn, .flexibleSpace,
            Item.copy, Item.save,
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        struct Spec { let label: String; let symbol: String; let action: Selector }
        let spec: Spec
        switch identifier {
        case Item.copy:
            spec = Spec(label: "Copy", symbol: "doc.on.doc", action: #selector(copyImage))
        case Item.save:
            spec = Spec(
                label: "Save", symbol: "square.and.arrow.down", action: #selector(saveImage)
            )
        case Item.crop:
            spec = Spec(label: "Crop", symbol: "crop", action: #selector(cropToSelection))
        case Item.reset:
            spec = Spec(
                label: "Reset Crop", symbol: "arrow.uturn.backward",
                action: #selector(resetCrop)
            )
        case Item.zoomOut:
            spec = Spec(
                label: "Zoom Out", symbol: "minus.magnifyingglass", action: #selector(zoomOut)
            )
        case Item.zoomFit:
            spec = Spec(
                label: "Fit", symbol: "arrow.up.left.and.arrow.down.right",
                action: #selector(zoomToFit)
            )
        case Item.zoomIn:
            spec = Spec(
                label: "Zoom In", symbol: "plus.magnifyingglass", action: #selector(zoomIn)
            )
        default: return nil
        }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = spec.label
        item.toolTip = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.target = self
        item.action = spec.action
        return item
    }
}
