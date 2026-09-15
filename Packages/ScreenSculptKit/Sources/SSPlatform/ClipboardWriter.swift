// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import AppKit
import SSImaging

/// Writes captures to the system pasteboard.
///
/// Lives in SSPlatform rather than SSExport because `NSPasteboard` is AppKit,
/// and the compute modules stay headless so their logic can be tested without a
/// window server. The SwiftLint rule `no_appkit_in_compute_modules` is what
/// caught this sitting in the wrong module.
@MainActor
public enum ClipboardWriter {

    public enum Failure: Error, LocalizedError {
        case rejected
        public var errorDescription: String? { "The clipboard rejected the image." }
    }

    /// Put the image on the pasteboard as **PNG**, not TIFF.
    ///
    /// `NSImage`'s default TIFF representation is large, and many applications
    /// paste it at the wrong size. PNG is what receivers actually want, and
    /// third-party clipboard managers handle it far more reliably.
    @discardableResult
    public static func copy(_ image: RasterImage) throws -> Int {
        let data = try ImageCodec.encode(image, as: .png)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else { throw Failure.rejected }
        return data.count
    }
}
