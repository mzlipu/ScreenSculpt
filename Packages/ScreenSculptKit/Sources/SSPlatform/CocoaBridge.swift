// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import SSGeometry

/// The single place AppKit's coordinate convention is converted to the model's.
///
/// Everything above this file speaks CoreGraphics convention — top-left origin,
/// Y increasing downward. Cocoa's bottom-left origin exists only here and in the
/// view layer.
@MainActor
public enum CocoaBridge {

    /// Snapshot every attached display.
    public static func currentTopology() -> DisplayTopology {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return .empty }

        // The pivot for the vertical flip: the union of all screen frames in
        // Cocoa space. Using the primary display's height instead is correct on
        // a single-display machine and wrong the moment a display sits above it.
        let cocoaUnion = screens.dropFirst().reduce(screens[0].frame) { $0.union($1.frame) }
        let unionRect = ScreenRect(cgRect: cocoaUnion)
        let maxY = unionRect.maxY

        let snapshots: [DisplaySnapshot] = screens.map { screen in
            let displayID = displayID(of: screen)
            let cocoa = ScreenRect(cgRect: screen.frame)
            // Flip: the rect's Cocoa top edge becomes its CG top edge.
            let cg = ScreenRect(
                origin: ScreenPoint(x: cocoa.minX, y: maxY - cocoa.maxY),
                size: cocoa.size
            )
            return DisplaySnapshot(
                displayID: displayID,
                uuid: uuidString(for: displayID),
                frame: cg,
                scale: PixelScale(Double(screen.backingScaleFactor)),
                isPrimary: screen == screens.first,
                localizedName: screen.localizedName
            )
        }

        return DisplayTopology(displays: snapshots, globalCocoaBounds: unionRect)
    }

    /// `CGDirectDisplayID` for a screen.
    ///
    /// `NSScreen.CGDirectDisplayID` only exists on macOS 26, so read the
    /// long-standing device description key instead.
    public static func displayID(of screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// Stable identifier that survives disconnect and reconnect, unlike the
    /// display ID. Anything persisted — pinned window positions especially —
    /// must key off this.
    public static func uuidString(for displayID: UInt32) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    public static func screen(for snapshot: DisplaySnapshot) -> NSScreen? {
        NSScreen.screens.first { displayID(of: $0) == snapshot.displayID }
    }

    // MARK: - Point conversion

    /// Cocoa global point (bottom-left origin) → CG global point.
    public static func toCG(_ point: NSPoint, topology: DisplayTopology) -> ScreenPoint {
        topology.cgPoint(fromCocoa: ScreenPoint(cgPoint: point))
    }

    /// CG global point → Cocoa global point.
    public static func toCocoa(_ point: ScreenPoint, topology: DisplayTopology) -> NSPoint {
        topology.cocoaPoint(fromCG: point).cgPoint
    }

    public static func toCG(_ rect: NSRect, topology: DisplayTopology) -> ScreenRect {
        topology.cgRect(fromCocoa: ScreenRect(cgRect: rect))
    }

    public static func toCocoa(_ rect: ScreenRect, topology: DisplayTopology) -> NSRect {
        topology.cocoaRect(fromCG: rect).cgRect
    }

    /// Current mouse location in CG global coordinates.
    public static func mouseLocation(topology: DisplayTopology) -> ScreenPoint {
        toCG(NSEvent.mouseLocation, topology: topology)
    }
}
