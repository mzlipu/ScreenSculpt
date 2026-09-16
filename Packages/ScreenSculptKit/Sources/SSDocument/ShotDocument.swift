// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSAnnotations
import SSGeometry
import SSImaging

/// A destructive edit to the underlying raster.
///
/// Operations are stored as *descriptions* rather than results, so the undo
/// stack costs an array of small enums rather than a stack of full-size images.
/// The two cases that do carry an image are bounded by the eviction policy in
/// ``UndoStack``.
///
/// This is also what gives the app its central semantic for free: raster
/// operations apply to `origin` and are structurally unable to see annotations.
public enum AppendEdge: String, Sendable, Equatable, Codable {
    case bottom, right
}

public enum RasterOp: Sendable, Equatable {
    case crop(ImageRect)
    case resize(ImageSize)
    case downscaleToOneX

    /// Add another capture below or beside this one.
    ///
    /// Only those two edges. Appending above or to the left would move the
    /// origin, and every annotation already placed is measured from it.
    case append(RasterImage, AppendEdge)

    /// Replaces everything with a pre-rendered image — used by flatten.
    /// Undoable, unlike the usual implementation of that command, because it is
    /// just one more entry in the list.
    case flatten(RasterImage)

    public static func == (lhs: RasterOp, rhs: RasterOp) -> Bool {
        switch (lhs, rhs) {
        case (.crop(let a), .crop(let b)): a == b
        case (.resize(let a), .resize(let b)): a == b
        case (.downscaleToOneX, .downscaleToOneX): true
        case (.flatten(let a), .flatten(let b)): a.cgImage === b.cgImage
        case (.append(let a, let ae), .append(let b, let be)):
            a.cgImage === b.cgImage && ae == be
        default: false
        }
    }
}

/// The editable state of one screenshot.
///
/// A struct, not a class. Undo is then a snapshot copy — cheap because the
/// arrays are copy-on-write — rather than a log of inverse operations, which is
/// where editors of this kind usually acquire their corrupt-undo bugs.
public struct ShotDocument: Sendable {

    /// The capture as it arrived. Never mutated.
    public let origin: RasterImage

    /// Applied in order over `origin` to produce the current raster.
    public var rasterOps: [RasterOp] = []

    /// Markup layered over the raster. Non-destructive: the pixels underneath
    /// survive until the document is flattened.
    public var annotations = OrderedAnnotations()

    /// Presentation wrapped around the finished image, if any.
    ///
    /// Outside `rasterOps` on purpose: padding moves the image origin, and
    /// annotations are positioned in image pixels, so applying it as an
    /// operation would shift every existing mark. It is applied once, after
    /// compositing.
    public var backdrop: Backdrop?

    /// Currently selected annotation, if any. Transient UI state, outside undo.
    public var selectedAnnotation: AnnotationID?

    /// Current marquee, in image pixels. Not part of undo history.
    public var selection: ImageRect?

    public let capturedAt: Date

    /// True when the capture spanned displays of differing scale, in which case
    /// no single pixels-per-point conversion is correct and measurement must be
    /// withheld rather than reported wrongly.
    public let measurementUnavailable: Bool

    public init(
        origin: RasterImage,
        capturedAt: Date = Date(),
        measurementUnavailable: Bool = false
    ) {
        self.origin = origin
        self.capturedAt = capturedAt
        self.measurementUnavailable = measurementUnavailable
    }

    /// The raster after applying every operation.
    ///
    /// Recomputed on demand and memoised by ``DocumentStore``; undoing a crop is
    /// therefore a cache hit rather than a re-render.
    public func render() -> RasterImage {
        // The backdrop is part of what the editor shows, not only of what gets
        // exported. A presentation frame you cannot see while arranging the
        // thing inside it is not much use.
        guard let backdrop else { return rasterOnly() }
        return backdrop.apply(to: rasterOnly())
    }

    /// The raster with operations applied but no backdrop.
    ///
    /// Needed on its own because the padding a backdrop adds is computed from
    /// this size, and annotations have to be offset by exactly that much.
    public func rasterOnly() -> RasterImage {
        var image = origin
        for op in rasterOps {
            switch op {
            case .crop(let rect):
                image = image.cropped(to: rect) ?? image
            case .resize(let size):
                image = image.resized(to: size) ?? image
            case .downscaleToOneX:
                image = image.downscaledTo1x() ?? image
            case .flatten(let flattened):
                image = flattened
            case .append(let addition, let edge):
                image = Compositor.append(addition, to: image, at: edge) ?? image
            }
        }
        return image
    }

    public var isCropped: Bool {
        rasterOps.contains { if case .crop = $0 { true } else { false } }
    }
}

/// One undoable step.
public struct DocumentSnapshot: Sendable, Equatable {
    public let rasterOps: [RasterOp]
    public let annotations: OrderedAnnotations

    public init(_ document: ShotDocument) {
        rasterOps = document.rasterOps
        annotations = document.annotations
    }
}

/// Snapshot-based undo with coalescing.
///
/// Deliberately not `NSUndoManager`'s invocation recording: registering the
/// inverse of every mutation is exactly the pattern that produces "undo left
/// the document in an impossible state" reports.
public struct UndoStack: Sendable {

    public struct Entry: Sendable {
        public let name: String
        public let before: DocumentSnapshot
        public let after: DocumentSnapshot
    }

    /// Bounded because `.flatten` entries hold a full-size image.
    public var limit = 50

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    public init() {}

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    public mutating func push(name: String, before: DocumentSnapshot, after: DocumentSnapshot) {
        guard before != after else { return }
        undoStack.append(Entry(name: name, before: before, after: after))
        redoStack.removeAll()
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
    }

    public mutating func undo() -> DocumentSnapshot? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(entry)
        return entry.before
    }

    public mutating func redo() -> DocumentSnapshot? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(entry)
        return entry.after
    }

    public mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
