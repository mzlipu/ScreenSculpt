// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SSGeometry
import SSImaging
import SSPlatform

/// Capture backed by ScreenCaptureKit.
///
/// There is deliberately no CoreGraphics fallback. `CGWindowListCreateImage`
/// and `CGDisplayCreateImage` are annotated `SCREEN_CAPTURE_OBSOLETE(…, 15.0)`
/// in the SDK, so they do not merely warn — they are unavailable. If SCK fails
/// there is nothing to fall back to, and surfacing a real error is better than
/// pretending otherwise.
public final class ScreenCaptureKitService: CaptureService {

    public init() {}

    public func capture(_ request: CaptureRequest) async throws -> CaptureResult {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw Self.mapPermissionError(error)
        }

        let topology = await MainActor.run { CocoaBridge.currentTopology() }

        switch request.mode {
        case .fullscreen(let displayID):
            return try await captureDisplay(
                displayID: displayID, content: content, topology: topology, request: request
            )
        case .area(let rect):
            return try await captureArea(
                rect, content: content, topology: topology, request: request
            )
        case .activeWindow:
            guard let window = Self.frontmostWindow(in: content) else {
                throw CaptureError.windowNotFound
            }
            return try await captureWindow(
                window, content: content, topology: topology, request: request
            )
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw CaptureError.windowNotFound
            }
            return try await captureWindow(
                window, content: content, topology: topology, request: request
            )
        }
    }

    // MARK: - Display

    private func captureDisplay(
        displayID: UInt32?,
        content: SCShareableContent,
        topology: DisplayTopology,
        request: CaptureRequest
    ) async throws -> CaptureResult {
        guard !content.displays.isEmpty else { throw CaptureError.noDisplaysAvailable }

        let target: SCDisplay
        if let displayID {
            let match = content.displays.first { $0.displayID == displayID }
            guard let match else { throw CaptureError.displayNotFound(displayID) }
            target = match
        } else {
            let cursor = await MainActor.run { CocoaBridge.mouseLocation(topology: topology) }
            let snapshot = topology.display(containing: cursor) ?? topology.primary
            target = content.displays.first { $0.displayID == snapshot?.displayID }
                ?? content.displays[0]
        }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let scale = PixelScale(pointPixelScale: filter.pointPixelScale)
        let config = Self.configuration(
            widthPoints: target.width, heightPoints: target.height,
            scale: scale, cursor: request.cursor
        )

        let image = try await Self.performCapture(filter: filter, config: config)
        let snapshot = topology.display(id: target.displayID)

        return CaptureResult(
            image: RasterImage(cgImage: image, pixelScale: scale),
            provenance: CaptureProvenance(
                sourceRect: snapshot?.frame,
                pixelScale: scale,
                displays: topology.displays,
                sourceDisplayID: target.displayID,
                spansMixedScales: false
            )
        )
    }

    // MARK: - Area

    private func captureArea(
        _ rect: ScreenRect,
        content: SCShareableContent,
        topology: DisplayTopology,
        request: CaptureRequest
    ) async throws -> CaptureResult {
        guard !rect.isEmpty else { throw CaptureError.emptyRegion }

        let dominant = topology.dominantDisplay(for: rect)
        let mixed = topology.spansMixedScales(rect)

        guard let displaySnapshot = dominant else { throw CaptureError.noDisplaysAvailable }
        let display = content.displays.first { $0.displayID == displaySnapshot.displayID }
        guard let display else { throw CaptureError.noDisplaysAvailable }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = PixelScale(pointPixelScale: filter.pointPixelScale)

        // sourceRect is relative to the display's own origin, in points.
        let local = CGRect(
            x: (rect.minX - displaySnapshot.frame.minX).value,
            y: (rect.minY - displaySnapshot.frame.minY).value,
            width: rect.width.value,
            height: rect.height.value
        )

        let config = Self.configuration(
            widthPoints: Int(rect.width.value.rounded()),
            heightPoints: Int(rect.height.value.rounded()),
            scale: scale,
            cursor: request.cursor
        )
        config.sourceRect = local

        let image = try await Self.performCapture(filter: filter, config: config)

        return CaptureResult(
            image: RasterImage(cgImage: image, pixelScale: scale),
            provenance: CaptureProvenance(
                sourceRect: rect,
                pixelScale: scale,
                displays: topology.displays,
                sourceDisplayID: display.displayID,
                // When true, measurement must be disabled rather than reported
                // wrongly: no single scale factor applies to the whole image.
                spansMixedScales: mixed
            )
        )
    }

    // MARK: - Window

    private func captureWindow(
        _ window: SCWindow,
        content: SCShareableContent,
        topology: DisplayTopology,
        request: CaptureRequest
    ) async throws -> CaptureResult {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = PixelScale(pointPixelScale: filter.pointPixelScale)

        let config = Self.configuration(
            widthPoints: Int(filter.contentRect.width.rounded()),
            heightPoints: Int(filter.contentRect.height.rounded()),
            scale: scale,
            cursor: .exclude
        )
        // Trim the drop shadow: it is rarely wanted and bloats the image.
        config.ignoreShadowsSingleWindow = true

        let image = try await Self.performCapture(filter: filter, config: config)
        let frame = ScreenRect(cgRect: window.frame)

        return CaptureResult(
            image: RasterImage(cgImage: image, pixelScale: scale),
            provenance: CaptureProvenance(
                sourceRect: frame,
                pixelScale: scale,
                displays: topology.displays,
                sourceDisplayID: topology.dominantDisplay(for: frame)?.displayID,
                spansMixedScales: false
            )
        )
    }

    // MARK: - Helpers

    private static func configuration(
        widthPoints: Int, heightPoints: Int, scale: PixelScale, cursor: CursorPolicy
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Output size is in PIXELS while sourceRect is in POINTS. Getting this
        // wrong yields a correct-looking but half-resolution capture on Retina.
        config.width = Int((Double(widthPoints) * scale.value).rounded())
        config.height = Int((Double(heightPoints) * scale.value).rounded())
        config.showsCursor = cursor == .include
        config.scalesToFit = false
        // .automatic may silently hand back a downscaled frame on Retina, which
        // would quietly destroy the pixel accuracy this app exists for.
        config.captureResolution = .best
        config.ignoreGlobalClipSingleWindow = true
        return config
    }

    private static func performCapture(
        filter: SCContentFilter, config: SCStreamConfiguration
    ) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            throw mapPermissionError(error)
        }
    }

    /// Frontmost window of the frontmost application, ordered by the window
    /// server's own z-order.
    ///
    /// `SCWindow` has no z-ordering, so ask CoreGraphics — `CGWindowListCopyWindowInfo`
    /// is metadata rather than pixels and is not deprecated.
    private static func frontmostWindow(in content: SCShareableContent) -> SCWindow? {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]]
        else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in info {
            guard
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                let windowID = entry[kCGWindowNumber as String] as? UInt32
            else { continue }
            if let match = content.windows.first(where: { $0.windowID == windowID }) {
                return match
            }
        }
        return nil
    }

    private static func mapPermissionError(_ error: any Error) -> CaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801:  // userDeclined
                return CGPreflightScreenCaptureAccess() ? .permissionStale : .permissionDenied
            case -3802, -3803:  // failedToStart / missingEntitlements
                return .permissionDenied
            default:
                break
            }
        }
        return .captureFailed(error)
    }
}
