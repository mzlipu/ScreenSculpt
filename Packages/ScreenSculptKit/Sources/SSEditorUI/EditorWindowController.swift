// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSAnnotations
import SSDocument
import SSGeometry
import SSImaging
import SSMeasure
import SSRender

/// The editor window: one capture, a canvas, and a toolbar.
///
/// Opens on the display the capture came from, which is what people expect and
/// is the reason `CaptureProvenance` records the source display at all.
@MainActor
public final class EditorWindowController: NSWindowController, NSWindowDelegate {

    public var onCopy: ((RasterImage) -> Void)?
    public var onSave: ((RasterImage) -> Void)?
    public var onClose: (() -> Void)?
    /// Transient one-line feedback for actions with no visible result.
    public var onStatusMessage: ((String) -> Void)?

    private let store: DocumentStore
    private let canvas: CanvasView
    private let tools: ToolController
    private let measurement: MeasurementController
    private var zoomLabel: NSToolbarItem?
    private var statusField: NSTextField?

    public init(image: RasterImage, measurementUnavailable: Bool = false, onScreen: NSScreen?) {
        store = DocumentStore(image: image, measurementUnavailable: measurementUnavailable)
        canvas = CanvasView(image: image)
        tools = ToolController(store: store)
        measurement = MeasurementController(store: store)

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
        canvas.store = store
        canvas.tools = tools
        canvas.measurement = measurement
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
        canvas.onAnnotationsChanged = { [weak self] in
            self?.window?.toolbar?.validateVisibleItems()
            self?.updateStatus()
        }
        canvas.onMeasurementChanged = { [weak self] in self?.updateStatus() }
        canvas.onStatusMessage = { [weak self] message in
            self?.onStatusMessage?(message)
        }
    }

    // MARK: - Tools

    @objc public func selectTool(_ sender: NSToolbarItem) {
        guard let kind = AnnotationKind.allCases.first(where: {
            $0.rawValue == sender.itemIdentifier.rawValue
        }) else {
            tools.tool = .select
            canvas.window?.toolbar?.validateVisibleItems()
            return
        }
        // Clicking the active tool returns to select, so there is always a way
        // back without hunting for a separate arrow button.
        tools.tool = tools.tool == .draw(kind) ? .select : .draw(kind)
        canvas.window?.toolbar?.validateVisibleItems()
        updateStatus()
    }

    @objc public func toolArrow() { chooseTool(.arrow) }
    @objc public func toolLine() { chooseTool(.line) }
    @objc public func toolRectangle() { chooseTool(.rectangle) }
    @objc public func toolOval() { chooseTool(.oval) }
    @objc public func toolText() { chooseTool(.text) }
    @objc public func toolFreehand() { chooseTool(.freehand) }
    @objc public func toolHighlighter() { chooseTool(.highlighter) }
    @objc public func toolCounter() { chooseTool(.counter) }
    @objc public func toolConceal() { chooseTool(.conceal) }
    @objc public func toolSelect() { chooseTool(nil) }

    // MARK: - Measurement

    @objc public func copyPixelColor() {
        if let copied = measurement.pickPixelColor() { onStatusMessage?("Copied \(copied)") }
    }

    @objc public func copyTextColor() {
        if let copied = measurement.pickTextColor() { onStatusMessage?("Copied \(copied)") }
    }

    @objc public func copyAverageColor() {
        if let copied = measurement.pickAverageColor() {
            onStatusMessage?("Copied average \(copied)")
        } else {
            onStatusMessage?("Select an area first")
        }
    }

    @objc public func toggleLogicalPoints() {
        measurement.showLogicalPoints.toggle()
        updateStatus()
    }

    @objc public func autoFitSelection() {
        measurement.autoFitSelection()
        refresh()
    }

    @objc public func compareContrast() {
        if let summary = measurement.captureForComparison() { onStatusMessage?(summary) }
        updateStatus()
    }

    @objc public func clearContrast() {
        measurement.clearComparison()
        updateStatus()
    }

    public func chooseTool(_ kind: AnnotationKind?) {
        tools.tool = kind.map { EditorTool.draw($0) } ?? .select
        window?.toolbar?.validateVisibleItems()
        updateStatus()
    }

    @objc public func deleteAnnotation() {
        store.deleteSelectedAnnotation()
        refresh()
    }

    @objc public func duplicateAnnotation() {
        store.duplicateSelectedAnnotation()
        refresh()
    }

    /// Merge annotations into the pixels.
    ///
    /// Worth doing before sharing: until it happens the hidden pixels under a
    /// blur are still in the document.
    @objc public func flattenAnnotations() {
        let count = store.annotations.count
        guard count > 0 else { return }
        store.flatten(using: AnnotationRenderer.flatten(store.document))
        refresh()
        // Flatten leaves the picture identical, so without a word it reads as
        // a button that does nothing.
        onStatusMessage?(
            count == 1
                ? "Merged 1 object into the image"
                : "Merged \(count) objects into the image"
        )
    }

    /// The image with annotations merged in — what every export path uses.
    private var exportImage: RasterImage {
        AnnotationRenderer.flatten(store.document)
    }

    private func refresh() {
        canvas.update(image: store.raster, selection: store.document.selection)
        canvas.refreshAnnotations()
        window?.toolbar?.validateVisibleItems()
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

    @objc public func copyImage() { onCopy?(exportImage) }
    @objc public func saveImage() { onSave?(exportImage) }

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

        // The active tool, because a modal drawing tool is otherwise invisible
        // state — there is no cue that the next drag will draw rather than
        // select.
        if let kind = tools.tool.kind { parts.append("\(kind.label) tool") }

        // The object count, because Flatten's whole effect is to consume
        // objects, and without this the button looks like it does nothing.
        let count = store.annotations.count
        if count > 0 {
            parts.append(count == 1 ? "1 object" : "\(count) objects")
        }

        if store.document.measurementUnavailable {
            // Honest about it rather than printing a number that is wrong for
            // half the image.
            parts.append("mixed-scale capture — measurements unavailable")
        }

        // Live readings take over the subtitle: while the pointer is on the
        // image, what is under it matters more than the file's dimensions.
        if let reading = measurement.readingSummary {
            parts = [reading] + parts
        } else if let hover = measurement.hoverSummary, measurement.isAvailable {
            parts = [hover] + parts
        }
        if let contrast = measurement.contrastSummary {
            parts.append(contrast)
        }

        window?.subtitle = parts.joined(separator: "  ·  ")
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
        static let flatten = NSToolbarItem.Identifier("flatten")
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [Item.crop, Item.reset, .space]
        identifiers += AnnotationKind.allCases.map {
            NSToolbarItem.Identifier($0.rawValue)
        }
        identifiers += [
            .flexibleSpace, Item.flatten, .space,
            Item.zoomOut, Item.zoomFit, Item.zoomIn, .flexibleSpace,
            Item.copy, Item.save,
        ]
        return identifiers
    }

    /// Grey out what cannot act right now, rather than letting it fail silently.
    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case Item.flatten: !store.annotations.isEmpty
        case Item.reset: store.document.isCropped
        case Item.crop: store.document.selection != nil
        default: true
        }
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        // Annotation tools are identified by their own raw value, so adding a
        // tool needs no toolbar plumbing at all.
        if let kind = AnnotationKind.allCases.first(where: { $0.rawValue == identifier.rawValue }) {
            return makeItem(
                identifier,
                label: kind.label,
                tooltip: "\(kind.label)  (\(kind.shortcut.uppercased()))",
                symbol: kind.symbol,
                action: #selector(selectTool(_:))
            )
        }

        return switch identifier {
        case Item.copy:
            makeItem(identifier, label: "Copy", symbol: "doc.on.doc", action: #selector(copyImage))
        case Item.save:
            makeItem(
                identifier, label: "Save", symbol: "square.and.arrow.down",
                action: #selector(saveImage)
            )
        case Item.crop:
            makeItem(
                identifier, label: "Crop", symbol: "crop", action: #selector(cropToSelection)
            )
        case Item.reset:
            makeItem(
                identifier, label: "Reset Crop", symbol: "arrow.uturn.backward",
                action: #selector(resetCrop)
            )
        case Item.flatten:
            makeItem(
                identifier, label: "Merge",
                tooltip: "Merge every annotation permanently into the pixels.\n"
                    + "The picture will look the same — but blurred areas can no "
                    + "longer be moved, and the hidden pixels are gone for good.",
                symbol: "square.stack.3d.down.forward",
                action: #selector(flattenAnnotations)
            )
        case Item.zoomOut:
            makeItem(
                identifier, label: "Zoom Out", symbol: "minus.magnifyingglass",
                action: #selector(zoomOut)
            )
        case Item.zoomFit:
            makeItem(
                identifier, label: "Fit", symbol: "arrow.up.left.and.arrow.down.right",
                action: #selector(zoomToFit)
            )
        case Item.zoomIn:
            makeItem(
                identifier, label: "Zoom In", symbol: "plus.magnifyingglass",
                action: #selector(zoomIn)
            )
        default:
            nil
        }
    }

    private func makeItem(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        tooltip: String? = nil,
        symbol: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.toolTip = tooltip ?? label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}
