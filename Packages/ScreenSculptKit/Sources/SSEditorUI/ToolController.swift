// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSAnnotations
import SSDocument
import SSGeometry

/// What the canvas is currently doing.
public enum EditorTool: Equatable, Sendable {
    case select
    case draw(AnnotationKind)

    public var kind: AnnotationKind? {
        if case .draw(let kind) = self { return kind }
        return nil
    }
}

/// Turns drags into annotations, and drags on annotations into edits.
///
/// Holds the whole gesture: which object, which handle, where it started, and
/// the snapshot to diff against when the mouse comes up. Keeping that here
/// rather than in the view is what lets a drag be one undo entry.
@MainActor
final class ToolController {

    enum Gesture {
        case none
        case creating(AnnotationID)
        case moving(AnnotationID, grabOffset: ImageVector, before: DocumentSnapshot)
        case resizing(AnnotationID, HandleRole, before: DocumentSnapshot)
    }

    private(set) var gesture: Gesture = .none
    var tool: EditorTool = .select
    var style = AnnotationStyle()

    private let store: DocumentStore
    private var freehandPoints: [ImagePoint] = []
    private var creationAnchor: ImagePoint = .zero

    init(store: DocumentStore) {
        self.store = store
    }

    /// True while a create, move or resize gesture is in flight.
    var gestureIsActive: Bool {
        if case .none = gesture { return false }
        return true
    }

    var isDrawing: Bool {
        if case .creating = gesture { return true }
        return false
    }

    /// The object being dragged, so the canvas can lift it into the drag scrim
    /// and leave the main layer untouched.
    var activeAnnotation: AnnotationID? {
        switch gesture {
        case .none: nil
        case .creating(let id), .moving(let id, _, _), .resizing(let id, _, _): id
        }
    }

    // MARK: - Mouse down

    /// Returns true when the controller took the event.
    func begin(at point: ImagePoint, tolerance: ImagePx, modifiers: NSEvent.ModifierFlags) -> Bool {
        if let kind = tool.kind {
            beginCreating(kind, at: point)
            return true
        }

        // Select tool: grab whatever is under the cursor, topmost first.
        guard let (annotation, hit) = store.annotations.hitTest(point, tolerance: tolerance) else {
            store.select(nil)
            return false
        }

        store.select(annotation.id)
        let before = store.snapshot()

        switch hit {
        case .handle(let role):
            gesture = .resizing(annotation.id, role, before: before)
        case .body:
            if modifiers.contains(.option) {
                // Option-drag duplicates, matching every other macOS editor.
                store.duplicateSelectedAnnotation()
                guard let copy = store.selectedAnnotation else { return true }
                gesture = .moving(
                    copy.id,
                    grabOffset: point - copy.bounds.origin,
                    before: before
                )
            } else {
                gesture = .moving(
                    annotation.id,
                    grabOffset: point - annotation.bounds.origin,
                    before: before
                )
            }
        }
        return true
    }

    private func beginCreating(_ kind: AnnotationKind, at point: ImagePoint) {
        creationAnchor = point
        freehandPoints = [point]

        let body: AnyAnnotationBody = switch kind {
        case .arrow: .arrow(ArrowBody(start: point, end: point))
        case .line: .line(LineBody(start: point, end: point))
        case .rectangle:
            .rectangle(RectangleBody(rect: ImageRect(corner: point, opposite: point)))
        case .oval: .oval(OvalBody(rect: ImageRect(corner: point, opposite: point)))
        case .text: .text(TextBody(text: "", origin: point))
        case .freehand: .freehand(FreehandBody(points: [point]))
        case .highlighter: .highlighter(HighlighterBody(points: [point]))
        case .counter:
            .counter(CounterBody(
                center: point, number: store.annotations.nextCounterNumber
            ))
        case .conceal:
            .conceal(ConcealBody(rect: ImageRect(corner: point, opposite: point)))
        }

        store.add(body, style: style)
        guard let id = store.selectedAnnotation?.id else { return }

        // A counter is placed by one click; everything else needs a drag.
        gesture = kind == .counter ? .none : .creating(id)
        if kind == .counter || kind == .text { tool = .select }
    }

    // MARK: - Drag

    func drag(
        to point: ImagePoint, modifiers: NSEvent.ModifierFlags,
        snap: inout SnapEngine?
    ) {
        switch gesture {
        case .none:
            return

        case .creating(let id):
            guard var annotation = store.annotations[id] else { return }
            annotation.body = updatedBodyWhileCreating(
                annotation.body, to: point, constrain: modifiers.contains(.shift)
            )
            store.previewUpdate(annotation)

        case .moving(let id, let grabOffset, _):
            guard var annotation = store.annotations[id] else { return }
            var target = point - grabOffset
            // Command suspends snapping, for when the guides get in the way.
            if snap != nil, !modifiers.contains(.command) {
                target = snap!.adjust(origin: target, size: annotation.bounds.size)
            }
            let delta = target - annotation.bounds.origin
            annotation.body = annotation.body.translated(by: delta)
            store.previewUpdate(annotation)

        case .resizing(let id, let role, _):
            guard var annotation = store.annotations[id] else { return }
            annotation.body = annotation.body.applying(
                HandleEdit(
                    role: role, location: point, constrain: modifiers.contains(.shift)
                ),
                style: annotation.style
            )
            store.previewUpdate(annotation)
        }
    }

    private func updatedBodyWhileCreating(
        _ body: AnyAnnotationBody, to point: ImagePoint, constrain: Bool
    ) -> AnyAnnotationBody {
        let anchor = creationAnchor
        switch body {
        case .arrow(var arrow):
            arrow.end = constrain ? Draw2.constrain(point, from: anchor) : point
            return .arrow(arrow)
        case .line(var line):
            line.end = constrain ? Draw2.constrain(point, from: anchor) : point
            return .line(line)
        case .rectangle(var rect):
            rect.rect = Draw2.box(from: anchor, to: point, square: constrain)
            return .rectangle(rect)
        case .oval(var oval):
            oval.rect = Draw2.box(from: anchor, to: point, square: constrain)
            return .oval(oval)
        case .conceal(var conceal):
            conceal.rect = Draw2.box(from: anchor, to: point, square: constrain)
            return .conceal(conceal)
        case .freehand:
            freehandPoints.append(point)
            return .freehand(FreehandBody(points: freehandPoints))
        case .highlighter:
            freehandPoints.append(point)
            return .highlighter(HighlighterBody(points: freehandPoints))
        case .text, .counter:
            return body
        }
    }

    // MARK: - Mouse up

    func end() {
        switch gesture {
        case .none:
            break

        case .creating(let id):
            finishCreating(id)

        case .moving(_, _, let before):
            store.commitDrag(name: "Move", from: before)

        case .resizing(_, _, let before):
            store.commitDrag(name: "Resize", from: before)
        }
        gesture = .none
        freehandPoints = []
    }

    private func finishCreating(_ id: AnnotationID) {
        guard var annotation = store.annotations[id] else { return }

        // Simplify freehand once, on commit. Thousands of raw samples make
        // hit-testing and serialisation expensive for no visual gain.
        switch annotation.body {
        case .freehand(let body):
            annotation.body = .freehand(
                FreehandBody(points: FreehandBody.simplified(body.points))
            )
        case .highlighter(let body):
            annotation.body = .highlighter(
                HighlighterBody(points: FreehandBody.simplified(body.points, epsilon: 2))
            )
        default:
            break
        }

        // A click with no drag leaves a degenerate object; drop it rather than
        // littering the canvas with invisible zero-size shapes.
        let box = annotation.bounds
        let isDegenerate = box.width.value < 3 && box.height.value < 3
        if isDegenerate, annotation.kind != .text, annotation.kind != .counter {
            store.deleteSelectedAnnotation()
            return
        }
        store.previewUpdate(annotation)
    }

    func cancel() {
        if case .creating(let id) = gesture {
            store.select(id)
            store.deleteSelectedAnnotation()
        }
        gesture = .none
        freehandPoints = []
    }
}

/// Geometry helpers the controller needs that are not on a body.
enum Draw2 {
    static func constrain(_ point: ImagePoint, from anchor: ImagePoint) -> ImagePoint {
        let dx = point.x.value - anchor.x.value
        let dy = point.y.value - anchor.y.value
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return ImagePoint(
            x: ImagePx(anchor.x.value + cos(angle) * length),
            y: ImagePx(anchor.y.value + sin(angle) * length)
        )
    }

    static func box(from anchor: ImagePoint, to point: ImagePoint, square: Bool) -> ImageRect {
        let rect = ImageRect(corner: anchor, opposite: point)
        guard square else { return rect }
        let side = max(rect.width.value, rect.height.value)
        return ImageRect(
            x: ImagePx(point.x >= anchor.x ? anchor.x.value : anchor.x.value - side),
            y: ImagePx(point.y >= anchor.y ? anchor.y.value : anchor.y.value - side),
            width: ImagePx(side), height: ImagePx(side)
        )
    }
}
