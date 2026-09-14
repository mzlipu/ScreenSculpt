// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation

// Screen space. The model uses the **CoreGraphics convention everywhere**:
// origin at the top-left of the primary display, Y increasing downward,
// measured in logical points.
//
// Cocoa's bottom-left convention exists only at the NSEvent/NSWindow boundary
// and is converted immediately by `CocoaBridge` in SSPlatform. Nothing in this
// module imports AppKit, so the conversion cannot be skipped by accident.

// MARK: - ScreenPoint / ScreenSize / ScreenRect

public struct ScreenPoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: LogicalPt
    public var y: LogicalPt

    public init(x: LogicalPt, y: LogicalPt) { self.x = x; self.y = y }

    public static let zero = ScreenPoint(x: 0, y: 0)
    public var description: String { "(\(x), \(y))" }

    public var cgPoint: CGPoint { CGPoint(x: x.cgFloat, y: y.cgFloat) }
    public init(cgPoint: CGPoint) { self.init(x: LogicalPt(cgPoint.x), y: LogicalPt(cgPoint.y)) }
}

public struct ScreenSize: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: LogicalPt
    public var height: LogicalPt

    public init(width: LogicalPt, height: LogicalPt) { self.width = width; self.height = height }

    public static let zero = ScreenSize(width: 0, height: 0)
    public var description: String { "\(width)×\(height)" }
    public var isEmpty: Bool { width <= .zero || height <= .zero }
    public var cgSize: CGSize { CGSize(width: width.cgFloat, height: height.cgFloat) }
}

public struct ScreenRect: Hashable, Codable, Sendable, CustomStringConvertible {
    public var origin: ScreenPoint
    public var size: ScreenSize

    public init(origin: ScreenPoint, size: ScreenSize) { self.origin = origin; self.size = size }
    public init(x: LogicalPt, y: LogicalPt, width: LogicalPt, height: LogicalPt) {
        self.init(origin: ScreenPoint(x: x, y: y), size: ScreenSize(width: width, height: height))
    }

    public init(corner a: ScreenPoint, opposite b: ScreenPoint) {
        let minX = LogicalPt.min(a.x, b.x), maxX = LogicalPt.max(a.x, b.x)
        let minY = LogicalPt.min(a.y, b.y), maxY = LogicalPt.max(a.y, b.y)
        self.init(
            origin: ScreenPoint(x: minX, y: minY),
            size: ScreenSize(width: maxX - minX, height: maxY - minY)
        )
    }

    public static let zero = ScreenRect(origin: .zero, size: .zero)
    public var description: String { "[\(origin) \(size)]" }

    public var minX: LogicalPt { origin.x }
    public var minY: LogicalPt { origin.y }
    public var maxX: LogicalPt { origin.x + size.width }
    public var maxY: LogicalPt { origin.y + size.height }
    public var midX: LogicalPt { origin.x + size.width / 2 }
    public var midY: LogicalPt { origin.y + size.height / 2 }
    public var width: LogicalPt { size.width }
    public var height: LogicalPt { size.height }
    public var center: ScreenPoint { ScreenPoint(x: midX, y: midY) }
    public var isEmpty: Bool { size.isEmpty }

    public var cgRect: CGRect { CGRect(origin: origin.cgPoint, size: size.cgSize) }
    public init(cgRect: CGRect) {
        self.init(
            x: LogicalPt(cgRect.origin.x), y: LogicalPt(cgRect.origin.y),
            width: LogicalPt(cgRect.size.width), height: LogicalPt(cgRect.size.height)
        )
    }

    public func contains(_ p: ScreenPoint) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func intersects(_ other: ScreenRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func intersection(_ other: ScreenRect) -> ScreenRect {
        let x0 = LogicalPt.max(minX, other.minX), x1 = LogicalPt.min(maxX, other.maxX)
        let y0 = LogicalPt.max(minY, other.minY), y1 = LogicalPt.min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return .zero }
        return ScreenRect(
            origin: ScreenPoint(x: x0, y: y0),
            size: ScreenSize(width: x1 - x0, height: y1 - y0)
        )
    }

    public func union(_ other: ScreenRect) -> ScreenRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = LogicalPt.min(minX, other.minX), x1 = LogicalPt.max(maxX, other.maxX)
        let y0 = LogicalPt.min(minY, other.minY), y1 = LogicalPt.max(maxY, other.maxY)
        return ScreenRect(
            origin: ScreenPoint(x: x0, y: y0),
            size: ScreenSize(width: x1 - x0, height: y1 - y0)
        )
    }

    /// Area of overlap, used to pick the display a rect mostly belongs to.
    public func overlapArea(_ other: ScreenRect) -> Double {
        let i = intersection(other)
        return i.width.value * i.height.value
    }
}

// MARK: - DisplaySnapshot

/// One display, frozen at a moment in time.
///
/// Deliberately a plain value with no `NSScreen` inside, so it can be recorded
/// in a document's provenance and survive the display being disconnected.
public struct DisplaySnapshot: Hashable, Codable, Sendable, Identifiable {
    /// `CGDirectDisplayID`. Not stable across disconnect/reconnect — persist
    /// `uuid` instead when you need to find this display again later.
    public let displayID: UInt32

    /// `CGDisplayCreateUUIDFromDisplayID`. Stable across undock/redock, which
    /// display IDs are not. Pinned-window positions must key off this.
    public let uuid: String?

    /// Frame in CG global space: top-left origin, Y down, logical points.
    public let frame: ScreenRect

    /// Backing scale factor of this display.
    public let scale: PixelScale

    public let isPrimary: Bool
    public let localizedName: String?

    public init(
        displayID: UInt32,
        uuid: String? = nil,
        frame: ScreenRect,
        scale: PixelScale,
        isPrimary: Bool = false,
        localizedName: String? = nil
    ) {
        self.displayID = displayID
        self.uuid = uuid
        self.frame = frame
        self.scale = scale
        self.isPrimary = isPrimary
        self.localizedName = localizedName
    }

    public var id: UInt32 { displayID }
}

// MARK: - DisplayTopology

/// The full arrangement of displays, plus the one piece of arithmetic that is
/// most often got wrong: the Cocoa ↔ CoreGraphics vertical flip.
///
/// The flip must use the **union of every screen frame**, not the primary
/// display's height. On a layout where a second display sits *above* the
/// primary one, using `NSScreen.main!.frame.maxY` puts every converted point
/// off by the height of the other monitor — and it looks perfectly correct on
/// a single-display development machine.
public struct DisplayTopology: Hashable, Codable, Sendable {
    public let displays: [DisplaySnapshot]

    /// Union of all display frames in **Cocoa** global space (bottom-left
    /// origin, Y up). This is the reference frame the flip pivots around.
    public let globalCocoaBounds: ScreenRect

    public init(displays: [DisplaySnapshot], globalCocoaBounds: ScreenRect) {
        self.displays = displays
        self.globalCocoaBounds = globalCocoaBounds
    }

    public static let empty = DisplayTopology(displays: [], globalCocoaBounds: .zero)

    public var primary: DisplaySnapshot? {
        displays.first(where: \.isPrimary) ?? displays.first
    }

    /// Union of all display frames in CG global space.
    public var globalBounds: ScreenRect {
        displays.map(\.frame).reduce(ScreenRect.zero) { $0.union($1) }
    }

    public func display(id: UInt32) -> DisplaySnapshot? {
        displays.first { $0.displayID == id }
    }

    public func display(uuid: String) -> DisplaySnapshot? {
        displays.first { $0.uuid == uuid }
    }

    /// The display containing `point`, in CG global space.
    public func display(containing point: ScreenPoint) -> DisplaySnapshot? {
        displays.first { $0.frame.contains(point) }
    }

    /// The display that `rect` mostly covers. Used to decide which display an
    /// area capture belongs to, and therefore which scale factor applies.
    public func dominantDisplay(for rect: ScreenRect) -> DisplaySnapshot? {
        displays.max { a, b in
            rect.overlapArea(a.frame) < rect.overlapArea(b.frame)
        }.flatMap { rect.overlapArea($0.frame) > 0 ? $0 : nil }
    }

    /// True when `rect` straddles displays of differing scale factors.
    ///
    /// A capture in this state has no single `PixelScale`, so measurement must
    /// be disabled for it rather than reported wrongly.
    public func spansMixedScales(_ rect: ScreenRect) -> Bool {
        let touched = displays.filter { rect.overlapArea($0.frame) > 0 }
        guard touched.count > 1 else { return false }
        let first = touched[0].scale
        return touched.contains { $0.scale != first }
    }

    // MARK: Cocoa ↔ CoreGraphics

    /// Cocoa global point (bottom-left origin, Y up) → CG global point.
    public func cgPoint(fromCocoa p: ScreenPoint) -> ScreenPoint {
        ScreenPoint(x: p.x, y: globalCocoaBounds.maxY - p.y)
    }

    /// CG global point → Cocoa global point.
    public func cocoaPoint(fromCG p: ScreenPoint) -> ScreenPoint {
        ScreenPoint(x: p.x, y: globalCocoaBounds.maxY - p.y)
    }

    /// Cocoa global rect → CG global rect. The origin moves from the rect's
    /// bottom-left to its top-left, so `maxY` is what gets flipped.
    public func cgRect(fromCocoa r: ScreenRect) -> ScreenRect {
        ScreenRect(
            origin: ScreenPoint(x: r.minX, y: globalCocoaBounds.maxY - r.maxY),
            size: r.size
        )
    }

    /// CG global rect → Cocoa global rect.
    public func cocoaRect(fromCG r: ScreenRect) -> ScreenRect {
        ScreenRect(
            origin: ScreenPoint(x: r.minX, y: globalCocoaBounds.maxY - r.maxY),
            size: r.size
        )
    }
}
