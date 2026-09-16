// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import Observation
import SSAnnotations
import SSGeometry
import SSImaging

/// Owns the document and is the only thing allowed to mutate it.
///
/// Every change goes through ``apply(name:_:)``, which snapshots, mutates,
/// diffs and records undo in one place. Nothing else writes `document`, so
/// "this edit forgot to register undo" cannot happen.
@Observable
@MainActor
public final class DocumentStore {

    public private(set) var document: ShotDocument
    public private(set) var undoStack = UndoStack()

    /// Memoised result of `document.render()`.
    ///
    /// Keyed on the backdrop as well as the op list. The backdrop is not an
    /// operation — it cannot be, since padding would shift every annotation —
    /// but it does change the rendered image, and a key that ignores it serves
    /// a stale raster to anything that had already rendered once.
    private var cachedRaster: RasterImage?
    private var cachedOps: [RasterOp] = []
    private var cachedBackdrop: Backdrop?

    /// Bumped whenever the rendered raster changes, so views can invalidate
    /// without diffing images.
    public internal(set) var revision: Int = 0

    public init(document: ShotDocument) {
        self.document = document
    }

    public convenience init(image: RasterImage, measurementUnavailable: Bool = false) {
        self.init(document: ShotDocument(
            origin: image, measurementUnavailable: measurementUnavailable
        ))
    }

    /// Current raster, recomputing only when the operation list has changed.
    public var raster: RasterImage {
        if let cachedRaster,
           cachedOps == document.rasterOps,
           cachedBackdrop == document.backdrop {
            return cachedRaster
        }
        let rendered = document.render()
        cachedRaster = rendered
        cachedOps = document.rasterOps
        cachedBackdrop = document.backdrop
        return rendered
    }

    public var size: ImageSize { raster.size }
    public var pixelScale: PixelScale { raster.pixelScale }

    // MARK: - Mutation

    /// The single mutation funnel.
    ///
    /// `name` appears in the Edit menu, so it should read as the action the user
    /// took ("Crop", "Resize"), not as an implementation detail.
    public func apply(name: String, _ mutate: (inout ShotDocument) -> Void) {
        let before = DocumentSnapshot(document)
        mutate(&document)
        let after = DocumentSnapshot(document)
        guard before != after else { return }
        undoStack.push(name: name, before: before, after: after)
        revision += 1
    }

    /// Selection is transient UI state, so it is deliberately outside undo —
    /// undoing a crop should not also restore a marquee the user has moved on
    /// from.
    public func setSelection(_ rect: ImageRect?) {
        document.selection = rect.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Operations

    public func crop(to rect: ImageRect) {
        let clamped = rect.intersection(ImageRect(size: size)).integralOutward()
        guard !clamped.isEmpty, clamped != ImageRect(size: size) else { return }
        apply(name: "Crop") { document in
            document.rasterOps.append(.crop(clamped))
            document.selection = nil
        }
    }

    /// Set or clear the presentation backdrop.
    ///
    /// Annotations move with it. A backdrop pads the image, which shifts the
    /// picture inside the canvas; anything already marked on it would otherwise
    /// stay where it was and end up pointing somewhere else entirely.
    public func setBackdrop(_ backdrop: Backdrop?) {
        let size = document.rasterOnly().size
        let before = document.backdrop?.padding(for: size) ?? 0
        let after = backdrop?.padding(for: size) ?? 0
        let shift = after - before

        apply(name: backdrop == nil ? "Remove Backdrop" : "Backdrop") { document in
            document.backdrop = backdrop
            guard shift != 0 else { return }
            let delta = ImageVector(dx: ImagePx(shift), dy: ImagePx(shift))
            for annotation in document.annotations.all {
                var moved = annotation
                moved.body = annotation.body.translated(by: delta)
                document.annotations.update(moved)
            }
        }
    }

    /// Add another capture below or beside this one.
    public func append(_ image: RasterImage, at edge: AppendEdge) {
        apply(name: "Add Capture") { document in
            document.rasterOps.append(.append(image, edge))
            document.selection = nil
        }
    }

    public func cropToSelection() {
        guard let selection = document.selection else { return }
        crop(to: selection)
    }

    public func resetCrop() {
        guard document.isCropped else { return }
        apply(name: "Reset Crop") { document in
            document.rasterOps.removeAll { if case .crop = $0 { true } else { false } }
            document.selection = nil
        }
    }

    public func resize(to newSize: ImageSize) {
        guard !newSize.isEmpty, newSize != size else { return }
        apply(name: "Resize") { $0.rasterOps.append(.resize(newSize)) }
    }

    public func downscaleToOneX() {
        guard pixelScale.isRetina else { return }
        apply(name: "Downscale to 1×") { $0.rasterOps.append(.downscaleToOneX) }
    }

    // MARK: - Undo

    public func undo() {
        guard let snapshot = undoStack.undo() else { return }
        restore(snapshot)
    }

    public func redo() {
        guard let snapshot = undoStack.redo() else { return }
        restore(snapshot)
    }

    private func restore(_ snapshot: DocumentSnapshot) {
        document.rasterOps = snapshot.rasterOps
        document.annotations = snapshot.annotations
        // Both selections are transient UI state; restoring a marquee or a
        // highlighted object the user has moved on from is disorienting.
        document.selection = nil
        document.selectedAnnotation = nil
        revision += 1
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
}

// MARK: - Annotations

extension DocumentStore {

    public var annotations: OrderedAnnotations { document.annotations }
    public var selectedAnnotation: Annotation? {
        document.selectedAnnotation.flatMap { document.annotations[$0] }
    }

    public func add(_ body: AnyAnnotationBody, style: AnnotationStyle) {
        let annotation = Annotation(z: ZIndex(0), style: style, body: body)
        apply(name: "Add \(body.kind.label)") { document in
            document.annotations.append(annotation)
            document.selectedAnnotation = annotation.id
        }
    }

    /// Commit a change to one annotation as a single undo entry.
    ///
    /// Live dragging calls ``previewUpdate(_:)`` instead and then commits once
    /// on mouse-up, so a drag is one undo step rather than two hundred.
    public func update(_ annotation: Annotation, name: String) {
        apply(name: name) { $0.annotations.update(annotation) }
    }

    /// Mutate without touching undo, for the duration of a drag.
    public func previewUpdate(_ annotation: Annotation) {
        document.annotations.update(annotation)
        revision += 1
    }

    /// Record one undo entry for a drag that has already been previewed.
    public func commitDrag(name: String, from before: DocumentSnapshot) {
        let after = DocumentSnapshot(document)
        guard before != after else { return }
        undoStack.push(name: name, before: before, after: after)
        revision += 1
    }

    public func snapshot() -> DocumentSnapshot { DocumentSnapshot(document) }

    public func select(_ id: AnnotationID?) {
        document.selectedAnnotation = id
        // Selecting raises to front, which is what people expect when they
        // click a partly hidden object and then drag it.
        if let id { document.annotations.bringToFront(id) }
        revision += 1
    }

    public func deleteSelectedAnnotation() {
        guard let id = document.selectedAnnotation else { return }
        apply(name: "Delete") { document in
            document.annotations.remove(id)
            document.selectedAnnotation = nil
        }
    }

    public func duplicateSelectedAnnotation() {
        guard let original = selectedAnnotation else { return }
        let offset = ImageVector(dx: 16, dy: 16)
        let copy = Annotation(
            z: ZIndex(0), style: original.style, body: original.body.translated(by: offset)
        )
        apply(name: "Duplicate") { document in
            document.annotations.append(copy)
            document.selectedAnnotation = copy.id
        }
    }

    public func restyleSelected(_ transform: (inout AnnotationStyle) -> Void) {
        guard var annotation = selectedAnnotation else { return }
        transform(&annotation.style)
        update(annotation, name: "Change style")
    }

    public func deleteAllAnnotations() {
        guard !document.annotations.isEmpty else { return }
        apply(name: "Delete All") { document in
            document.annotations = OrderedAnnotations()
            document.selectedAnnotation = nil
        }
    }

    /// Merge annotations into the raster.
    ///
    /// Undoable, unlike most implementations of this command, because it is
    /// just one more `RasterOp` on the list.
    public func flatten(using flattened: RasterImage) {
        guard !document.annotations.isEmpty else { return }
        apply(name: "Flatten") { document in
            document.rasterOps.append(.flatten(flattened))
            document.annotations = OrderedAnnotations()
            document.selectedAnnotation = nil
        }
    }
}
