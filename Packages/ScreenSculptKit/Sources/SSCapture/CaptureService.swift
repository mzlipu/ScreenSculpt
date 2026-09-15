// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSGeometry
import SSImaging

public enum CaptureMode: Sendable, Equatable {
    /// One whole display. `nil` means the display containing the cursor.
    case fullscreen(displayID: UInt32?)
    /// A rectangle in CG global coordinates.
    case area(ScreenRect)
    /// The frontmost window of the frontmost application.
    case activeWindow
    /// A specific window, by `CGWindowID`.
    case window(id: UInt32)
}

public enum CursorPolicy: String, Sendable, CaseIterable {
    case include, exclude
}

public struct CaptureRequest: Sendable {
    public var mode: CaptureMode
    public var cursor: CursorPolicy

    public init(mode: CaptureMode, cursor: CursorPolicy = .exclude) {
        self.mode = mode
        self.cursor = cursor
    }
}

/// Where a capture came from.
///
/// Carried on every result so the editor can open on the originating display,
/// and so measurement can convert between pixels and points — or refuse to,
/// when the capture spans displays of differing scale and no single conversion
/// is correct.
public struct CaptureProvenance: Sendable {
    public let capturedAt: Date
    public let sourceRect: ScreenRect?
    public let pixelScale: PixelScale
    public let displays: [DisplaySnapshot]
    public let sourceDisplayID: UInt32?
    public let spansMixedScales: Bool

    public init(
        capturedAt: Date = Date(),
        sourceRect: ScreenRect?,
        pixelScale: PixelScale,
        displays: [DisplaySnapshot],
        sourceDisplayID: UInt32?,
        spansMixedScales: Bool
    ) {
        self.capturedAt = capturedAt
        self.sourceRect = sourceRect
        self.pixelScale = pixelScale
        self.displays = displays
        self.sourceDisplayID = sourceDisplayID
        self.spansMixedScales = spansMixedScales
    }
}

public struct CaptureResult: Sendable {
    public let image: RasterImage
    public let provenance: CaptureProvenance

    public init(image: RasterImage, provenance: CaptureProvenance) {
        self.image = image
        self.provenance = provenance
    }
}

public enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case permissionStale
    case noDisplaysAvailable
    case displayNotFound(UInt32)
    case windowNotFound
    case emptyRegion
    case captureFailed(any Error)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "ScreenSculpt needs permission to record the screen."
        case .permissionStale:
            """
            macOS lists ScreenSculpt as approved but is not honouring it. \
            Remove and re-add it in Privacy & Security, then relaunch.
            """
        case .noDisplaysAvailable:
            "No displays are available to capture."
        case .displayNotFound(let id):
            "Display \(id) is no longer connected."
        case .windowNotFound:
            "Could not identify the window to capture."
        case .emptyRegion:
            "The selected region is empty."
        case .captureFailed(let underlying):
            "Capture failed: \(underlying.localizedDescription)"
        }
    }
}

/// Abstracts the capture backend so the UI layer can be driven by a fake in
/// tests, where there is no window server and no TCC grant.
public protocol CaptureService: Sendable {
    func capture(_ request: CaptureRequest) async throws -> CaptureResult
}
