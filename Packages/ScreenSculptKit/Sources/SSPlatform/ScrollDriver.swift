// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation

/// Synthesises scroll input.
///
/// Delivery is per-process by default. `CGEventPostToPid` puts the event
/// straight into one application's queue, which buys three things at once: the
/// target need not be frontmost, the user's own cursor is never moved, and
/// session-level event taps installed by third-party scroll utilities are
/// bypassed — those taps are the usual reason a captured page jumps three times
/// further than it was told to.
///
/// Needs the Accessibility grant, and nothing here checks for it; the caller
/// does, so the request can be made at the moment the user asks to scroll
/// rather than at launch.
public struct ScrollDriver: Sendable {

    public enum Target: Sendable {
        /// Delivered to one process.
        case process(pid_t)
        /// Delivered as though from the hardware, for applications that read
        /// HID more directly and ignore a posted event.
        case systemWide
    }

    public init() {}

    /// Scroll by a number of points, as one gesture.
    ///
    /// Momentum is never generated, because momentum is added by the *sender*:
    /// a real trackpad driver appends the coasting events itself. Emitting a
    /// plain began/changed/ended sequence and leaving the momentum phase at
    /// none means the page stops exactly where it was put, which is the whole
    /// requirement for a frame that has to be measured.
    ///
    /// - Parameter deltaY: negative moves further down the document, matching
    ///   the sign an application sees from a real downward swipe.
    public func scroll(
        deltaY: Int, at location: CGPoint, to target: Target, steps: Int = 6
    ) {
        guard deltaY != 0, steps > 0 else { return }

        let perStep = deltaY / steps
        let remainder = deltaY - perStep * steps

        for index in 0..<steps {
            let amount = perStep + (index == steps - 1 ? remainder : 0)
            let phase: CGScrollPhase = index == 0 ? .began : .changed
            post(delta: amount, phase: phase, at: location, to: target)
        }
        // A closing zero-delta event with the ended phase. Without it an
        // application that tracks gesture state keeps waiting for the rest of
        // the swipe and may not commit the scroll at all.
        post(delta: 0, phase: .ended, at: location, to: target)
    }

    private func post(
        delta: Int, phase: CGScrollPhase, at location: CGPoint, to target: Target
    ) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0
        ) else { return }

        event.location = location
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        // Explicitly none. Left unset, some applications infer coasting and
        // keep moving after the last event, which puts the next captured frame
        // somewhere unpredictable.
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase, value: Int64(CGMomentumScrollPhase.none.rawValue)
        )
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))

        switch target {
        case .process(let pid): event.postToPid(pid)
        case .systemWide: event.post(tap: .cghidEventTap)
        }
    }
}

/// Which application owns a point on screen.
///
/// `CGWindowListCopyWindowInfo` is metadata only and is not deprecated, unlike
/// the image-producing calls beside it — and it is the only thing that answers
/// this respecting z-order, which `SCWindow` cannot.
public enum WindowLocator {

    /// The process owning the frontmost window under a point, in CG global
    /// coordinates.
    public static func processOwningWindow(at point: CGPoint) -> pid_t? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        for window in windows {
            guard
                let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                rect.contains(point)
            else { continue }
            // The list is front-to-back, so the first hit is the visible one.
            return pid
        }
        return nil
    }
}
