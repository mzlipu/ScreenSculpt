// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSCapture
import SSGeometry
import SSImaging
import SSPlatform

/// Interactive region selection.
///
/// Every display is captured *first*, and each overlay then shows its own
/// display's frozen frame. Three things fall out of that ordering for free:
///
///  * the screen appears frozen, so animations and hover states cannot move
///    under the marquee while the user is dragging;
///  * the result is cropped from the frozen frame rather than re-captured, so
///    the overlay can never appear in its own screenshot;
///  * the magnifier loupe samples an exact, already-captured buffer instead of
///    re-grabbing the screen on every mouse move.
///
/// One window per `NSScreen`, never one window spanning the union: a single
/// window has one backing scale factor, so on a mixed 2×/1× setup the crosshair
/// would be wrong on one of the displays.
@MainActor
public final class AreaSelectionController {

    public struct Selection: Sendable {
        public let rect: ScreenRect
        public let image: RasterImage
        public let displayID: UInt32
        public let pixelScale: PixelScale
    }

    private var windows: [SelectionOverlayWindow] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var frozen: [UInt32: CaptureResult] = [:]
    private var topology: DisplayTopology = .empty

    private let captureService: any CaptureService

    public init(captureService: any CaptureService) {
        self.captureService = captureService
    }

    /// Present the overlay and wait. Returns nil if the user pressed Escape,
    /// right-clicked, or selected a degenerate region.
    public func selectRegion() async throws -> Selection? {
        topology = CocoaBridge.currentTopology()
        guard !topology.displays.isEmpty else { throw CaptureError.noDisplaysAvailable }

        // Freeze first, overlays second. Reversing this order shows the
        // overlays inside their own freeze frame.
        frozen = [:]
        for display in topology.displays {
            let result = try await captureService.capture(
                CaptureRequest(mode: .fullscreen(displayID: display.displayID), cursor: .exclude)
            )
            frozen[display.displayID] = result
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            presentOverlays()
        }
    }

    private func presentOverlays() {
        for snapshot in topology.displays {
            guard
                let screen = CocoaBridge.screen(for: snapshot),
                let capture = frozen[snapshot.displayID]
            else { continue }

            let window = SelectionOverlayWindow(
                screen: screen,
                snapshot: snapshot,
                frozenImage: capture.image
            )
            window.onCommit = { [weak self] localRect in
                self?.finish(localRect: localRect, snapshot: snapshot)
            }
            window.onCancel = { [weak self] in self?.finish(localRect: nil, snapshot: nil) }
            window.onCursorMoved = { [weak self] in self?.dismissTooltips(except: window) }
            windows.append(window)
            window.orderFrontRegardless()
        }

        guard !windows.isEmpty else { return finish(localRect: nil, snapshot: nil) }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func dismissTooltips(except active: SelectionOverlayWindow) {
        for window in windows where window !== active {
            window.clearSelection()
        }
    }

    /// `localRect` is in the display's own coordinates, top-left origin, points.
    private func finish(localRect: ImageRect?, snapshot: DisplaySnapshot?) {
        let windowsToClose = windows
        windows = []
        for window in windowsToClose { window.orderOut(nil) }

        guard
            let localRect, let snapshot,
            let capture = frozen[snapshot.displayID],
            !localRect.isEmpty
        else {
            frozen = [:]
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }

        let scale = capture.image.pixelScale

        // The overlay works in points; the frozen frame is in device pixels.
        let pixelRect = ImageRect(
            x: ImagePx(localRect.minX.value * scale.value),
            y: ImagePx(localRect.minY.value * scale.value),
            width: ImagePx(localRect.width.value * scale.value),
            height: ImagePx(localRect.height.value * scale.value)
        )

        let cropped = capture.image.cropped(to: pixelRect)
        frozen = [:]

        guard let cropped else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }

        let globalRect = ScreenRect(
            origin: ScreenPoint(
                x: snapshot.frame.minX + LogicalPt(localRect.minX.value),
                y: snapshot.frame.minY + LogicalPt(localRect.minY.value)
            ),
            size: ScreenSize(
                width: LogicalPt(localRect.width.value),
                height: LogicalPt(localRect.height.value)
            )
        )

        continuation?.resume(returning: Selection(
            rect: globalRect,
            image: cropped,
            displayID: snapshot.displayID,
            pixelScale: scale
        ))
        continuation = nil
    }
}
