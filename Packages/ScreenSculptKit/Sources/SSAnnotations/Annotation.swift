// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

/// Type-erased body.
///
/// An enum rather than an existential box, for three reasons: adding a tool
/// becomes a compile error everywhere it must be handled, `Codable` synthesis
/// works with a discriminant, and `Equatable` comes free — which is what drives
/// dirty-rect invalidation.
///
/// The cost is the forwarding below. It is mechanical and it changes about once
/// a quarter, which is cheaper than a macro target and far cheaper than
/// debugging an existential.
public enum AnyAnnotationBody: Codable, Sendable, Equatable {
    case arrow(ArrowBody)
    case line(LineBody)
    case rectangle(RectangleBody)
    case oval(OvalBody)
    case text(TextBody)
    case freehand(FreehandBody)
    case highlighter(HighlighterBody)
    case counter(CounterBody)
    case conceal(ConcealBody)
    case spotlight(SpotlightBody)
    case magnifier(MagnifierBody)
    case ruler(RulerBody)
    case imageOverlay(ImageOverlayBody)

    public var kind: AnnotationKind {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .oval: .oval
        case .text: .text
        case .freehand: .freehand
        case .highlighter: .highlighter
        case .counter: .counter
        case .conceal: .conceal
        case .spotlight: .spotlight
        case .magnifier: .magnifier
        case .ruler: .ruler
        case .imageOverlay: .imageOverlay
        }
    }

    // MARK: Forwarding

    public var bounds: ImageRect {
        switch self {
        case .arrow(let body): body.bounds
        case .line(let body): body.bounds
        case .rectangle(let body): body.bounds
        case .oval(let body): body.bounds
        case .text(let body): body.bounds
        case .freehand(let body): body.bounds
        case .highlighter(let body): body.bounds
        case .counter(let body): body.bounds
        case .conceal(let body): body.bounds
        case .spotlight(let body): body.bounds
        case .magnifier(let body): body.bounds
        case .ruler(let body): body.bounds
        case .imageOverlay(let body): body.bounds
        }
    }

    public func dirtyBounds(style: AnnotationStyle) -> ImageRect {
        switch self {
        case .arrow(let body): body.dirtyBounds(style: style)
        case .line(let body): body.dirtyBounds(style: style)
        case .rectangle(let body): body.dirtyBounds(style: style)
        case .oval(let body): body.dirtyBounds(style: style)
        case .text(let body): body.dirtyBounds(style: style)
        case .freehand(let body): body.dirtyBounds(style: style)
        case .highlighter(let body): body.dirtyBounds(style: style)
        case .counter(let body): body.dirtyBounds(style: style)
        case .conceal(let body): body.dirtyBounds(style: style)
        case .spotlight(let body): body.dirtyBounds(style: style)
        case .magnifier(let body): body.dirtyBounds(style: style)
        case .ruler(let body): body.dirtyBounds(style: style)
        case .imageOverlay(let body): body.dirtyBounds(style: style)
        }
    }

    public func handles(style: AnnotationStyle) -> [Handle] {
        switch self {
        case .arrow(let body): body.handles(style: style)
        case .line(let body): body.handles(style: style)
        case .rectangle(let body): body.handles(style: style)
        case .oval(let body): body.handles(style: style)
        case .text(let body): body.handles(style: style)
        case .freehand(let body): body.handles(style: style)
        case .highlighter(let body): body.handles(style: style)
        case .counter(let body): body.handles(style: style)
        case .conceal(let body): body.handles(style: style)
        case .spotlight(let body): body.handles(style: style)
        case .magnifier(let body): body.handles(style: style)
        case .ruler(let body): body.handles(style: style)
        case .imageOverlay(let body): body.handles(style: style)
        }
    }

    public func applying(_ edit: HandleEdit, style: AnnotationStyle) -> AnyAnnotationBody {
        switch self {
        case .arrow(let body): .arrow(body.applying(edit, style: style))
        case .line(let body): .line(body.applying(edit, style: style))
        case .rectangle(let body): .rectangle(body.applying(edit, style: style))
        case .oval(let body): .oval(body.applying(edit, style: style))
        case .text(let body): .text(body.applying(edit, style: style))
        case .freehand(let body): .freehand(body.applying(edit, style: style))
        case .highlighter(let body): .highlighter(body.applying(edit, style: style))
        case .counter(let body): .counter(body.applying(edit, style: style))
        case .conceal(let body): .conceal(body.applying(edit, style: style))
        case .spotlight(let body): .spotlight(body.applying(edit, style: style))
        case .magnifier(let body): .magnifier(body.applying(edit, style: style))
        case .ruler(let body): .ruler(body.applying(edit, style: style))
        case .imageOverlay(let body): .imageOverlay(body.applying(edit, style: style))
        }
    }

    public func translated(by delta: ImageVector) -> AnyAnnotationBody {
        switch self {
        case .arrow(let body): .arrow(body.translated(by: delta))
        case .line(let body): .line(body.translated(by: delta))
        case .rectangle(let body): .rectangle(body.translated(by: delta))
        case .oval(let body): .oval(body.translated(by: delta))
        case .text(let body): .text(body.translated(by: delta))
        case .freehand(let body): .freehand(body.translated(by: delta))
        case .highlighter(let body): .highlighter(body.translated(by: delta))
        case .counter(let body): .counter(body.translated(by: delta))
        case .conceal(let body): .conceal(body.translated(by: delta))
        case .spotlight(let body): .spotlight(body.translated(by: delta))
        case .magnifier(let body): .magnifier(body.translated(by: delta))
        case .ruler(let body): .ruler(body.translated(by: delta))
        case .imageOverlay(let body): .imageOverlay(body.translated(by: delta))
        }
    }

    public func hitTest(
        _ point: ImagePoint, tolerance: ImagePx, style: AnnotationStyle
    ) -> HitResult? {
        switch self {
        case .arrow(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .line(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .rectangle(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .oval(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .text(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .freehand(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .highlighter(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .counter(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .conceal(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .spotlight(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .magnifier(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .ruler(let body): body.hitTest(point, tolerance: tolerance, style: style)
        case .imageOverlay(let body):
            body.hitTest(point, tolerance: tolerance, style: style)
        }
    }

    public func draw(in context: CGContext, style: AnnotationStyle, render: RenderContext) {
        switch self {
        case .arrow(let body): body.draw(in: context, style: style, render: render)
        case .line(let body): body.draw(in: context, style: style, render: render)
        case .rectangle(let body): body.draw(in: context, style: style, render: render)
        case .oval(let body): body.draw(in: context, style: style, render: render)
        case .text(let body): body.draw(in: context, style: style, render: render)
        case .freehand(let body): body.draw(in: context, style: style, render: render)
        case .highlighter(let body): body.draw(in: context, style: style, render: render)
        case .counter(let body): body.draw(in: context, style: style, render: render)
        case .conceal(let body): body.draw(in: context, style: style, render: render)
        case .spotlight(let body): body.draw(in: context, style: style, render: render)
        case .magnifier(let body): body.draw(in: context, style: style, render: render)
        case .ruler(let body): body.draw(in: context, style: style, render: render)
        case .imageOverlay(let body):
            body.draw(in: context, style: style, render: render)
        }
    }

    public func snapCandidates(id: AnnotationID) -> [SnapCandidate] {
        switch self {
        case .arrow(let body): body.snapCandidates(id: id)
        case .line(let body): body.snapCandidates(id: id)
        case .rectangle(let body): body.snapCandidates(id: id)
        case .oval(let body): body.snapCandidates(id: id)
        case .text(let body): body.snapCandidates(id: id)
        case .freehand(let body): body.snapCandidates(id: id)
        case .highlighter(let body): body.snapCandidates(id: id)
        case .counter(let body): body.snapCandidates(id: id)
        case .conceal(let body): body.snapCandidates(id: id)
        case .spotlight(let body): body.snapCandidates(id: id)
        case .magnifier(let body): body.snapCandidates(id: id)
        case .ruler(let body): body.snapCandidates(id: id)
        case .imageOverlay(let body): body.snapCandidates(id: id)
        }
    }

    /// The conceal body, if this is one. Lets the renderer find the objects
    /// that need the base image without switching over every case.
    public var concealBody: ConcealBody? {
        if case .conceal(let body) = self { return body }
        return nil
    }

    /// Bodies whose content the renderer has to supply, for the same reason.
    public var magnifierBody: MagnifierBody? {
        if case .magnifier(let body) = self { return body }
        return nil
    }

    public var imageOverlayBody: ImageOverlayBody? {
        if case .imageOverlay(let body) = self { return body }
        return nil
    }
}

// MARK: - Element

public struct Annotation: Identifiable, Codable, Sendable, Equatable {
    public let id: AnnotationID
    public var z: ZIndex
    public var style: AnnotationStyle
    public var body: AnyAnnotationBody

    public init(
        id: AnnotationID = AnnotationID(),
        z: ZIndex,
        style: AnnotationStyle,
        body: AnyAnnotationBody
    ) {
        self.id = id
        self.z = z
        self.style = style
        self.body = body
    }

    public var kind: AnnotationKind { body.kind }
    public var bounds: ImageRect { body.bounds }
    public var dirtyBounds: ImageRect { body.dirtyBounds(style: style) }

    public func hitTest(_ point: ImagePoint, tolerance: ImagePx) -> HitResult? {
        body.hitTest(point, tolerance: tolerance, style: style)
    }

    public func handles() -> [Handle] { body.handles(style: style) }
}

// MARK: - Ordered collection

/// Annotations kept in draw order.
///
/// Sorted by `(z, id)` so serialisation is byte-stable — which matters because
/// the golden-image render tests compare exported files.
public struct OrderedAnnotations: Codable, Sendable, Equatable {
    private var storage: [Annotation] = []

    public init() {}
    public init(_ annotations: [Annotation]) {
        storage = annotations
        sort()
    }

    public var all: [Annotation] { storage }
    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }

    private mutating func sort() {
        storage.sort {
            $0.z == $1.z ? $0.id.raw.uuidString < $1.id.raw.uuidString : $0.z < $1.z
        }
    }

    private var maxZ: ZIndex { storage.last?.z ?? ZIndex(0) }

    public mutating func append(_ annotation: Annotation) {
        var copy = annotation
        copy.z = ZIndex(maxZ.value + 1)
        storage.append(copy)
        sort()
    }

    public mutating func remove(_ id: AnnotationID) {
        storage.removeAll { $0.id == id }
    }

    public mutating func update(_ annotation: Annotation) {
        guard let index = storage.firstIndex(where: { $0.id == annotation.id }) else { return }
        storage[index] = annotation
        sort()
    }

    public subscript(id: AnnotationID) -> Annotation? {
        storage.first { $0.id == id }
    }

    /// Bring to front: one field write, no renumbering.
    public mutating func bringToFront(_ id: AnnotationID) {
        guard var annotation = self[id], annotation.z != maxZ else { return }
        annotation.z = ZIndex(maxZ.value + 1)
        update(annotation)
    }

    public mutating func sendToBack(_ id: AnnotationID) {
        guard var annotation = self[id] else { return }
        annotation.z = ZIndex((storage.first?.z.value ?? 0) - 1)
        update(annotation)
    }

    /// Topmost annotation under `point`. Iterates back to front, because the
    /// object drawn last is the one the user sees and expects to grab.
    public func hitTest(_ point: ImagePoint, tolerance: ImagePx) -> (Annotation, HitResult)? {
        for annotation in storage.reversed() {
            if let result = annotation.hitTest(point, tolerance: tolerance) {
                return (annotation, result)
            }
        }
        return nil
    }

    public func snapCandidates(excluding id: AnnotationID?) -> [SnapCandidate] {
        storage.filter { $0.id != id }.flatMap { $0.body.snapCandidates(id: $0.id) }
    }

    /// Collapse fractional depths back to integers.
    ///
    /// Midpoint insertion underflows after roughly 50 inserts between the same
    /// pair; calling this at save time keeps that from ever mattering.
    public mutating func renormalise() {
        for index in storage.indices { storage[index].z = ZIndex(Double(index)) }
    }

    public var nextCounterNumber: Int {
        let used = storage.compactMap { annotation -> Int? in
            if case .counter(let body) = annotation.body { return body.number }
            return nil
        }
        return (used.max() ?? 0) + 1
    }
}
