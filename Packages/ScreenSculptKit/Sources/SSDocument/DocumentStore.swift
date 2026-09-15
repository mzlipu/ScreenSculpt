// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import Observation
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

    /// Memoised result of `document.render()`, keyed on the op list.
    private var cachedRaster: RasterImage?
    private var cachedOps: [RasterOp] = []

    /// Bumped whenever the rendered raster changes, so views can invalidate
    /// without diffing images.
    public private(set) var revision: Int = 0

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
        if let cachedRaster, cachedOps == document.rasterOps { return cachedRaster }
        let rendered = document.render()
        cachedRaster = rendered
        cachedOps = document.rasterOps
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
        document.rasterOps = snapshot.rasterOps
        document.selection = nil
        revision += 1
    }

    public func redo() {
        guard let snapshot = undoStack.redo() else { return }
        document.rasterOps = snapshot.rasterOps
        document.selection = nil
        revision += 1
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
}
