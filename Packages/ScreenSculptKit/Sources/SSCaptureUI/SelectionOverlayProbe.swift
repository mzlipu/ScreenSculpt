// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import CoreGraphics
import SSGeometry
import SSImaging

/// Builds a selection overlay and throws it away, to prove construction works.
///
/// Exists because the overlay is created through `NSWindow`'s initialiser chain,
/// which is easy to get subtly wrong in a way that compiles cleanly and then
/// traps at runtime. `ScreenSculpt --diagnose` calls this so the failure is one
/// line of output instead of a crash report.
@MainActor
public enum SelectionOverlayProbe {

    public static func canConstruct() -> Bool {
        guard let screen = NSScreen.main else { return false }
        guard let context = CGContext(
            data: nil, width: 8, height: 8,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return false }

        let window = SelectionOverlayWindow(
            screen: screen,
            snapshot: DisplaySnapshot(
                displayID: 0,
                frame: ScreenRect(cgRect: screen.frame),
                scale: PixelScale(Double(screen.backingScaleFactor))
            ),
            frozenImage: RasterImage(cgImage: image, pixelScale: .x1)
        )
        window.orderOut(nil)
        return window.contentView != nil
    }
}
