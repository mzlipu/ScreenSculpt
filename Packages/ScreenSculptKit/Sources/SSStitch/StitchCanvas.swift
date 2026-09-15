// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Darwin
import Foundation
import SSGeometry
import SSImaging

public enum StitchCanvasError: Error, LocalizedError {
    case invalidSize
    case couldNotAllocate(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSize: "The capture area is too small to stitch."
        case .couldNotAllocate(let detail): "Could not reserve scratch space: \(detail)"
        }
    }
}

/// The growing image a scroll is assembled into, backed by a file rather than
/// by memory.
///
/// A long page reaches sizes no bitmap can hold: 200,000 rows at 1200 pixels is
/// 960 MB of RGBA, and `CGImage` wants that contiguous and resident. The pixels
/// therefore live in a sparse scratch file.
///
/// Only a **window** of that file is mapped at a time, and this is the part
/// worth knowing. Mapping the whole file and trusting the kernel to shed pages
/// does not work here: measured on macOS 26, a shared file mapping keeps every
/// page it has touched resident, and neither `madvise(MADV_DONTNEED)`,
/// `MADV_FREE`, nor `msync` with `MS_KILLPAGES` or `MS_DEACTIVATE` gives any of
/// it back. Resident memory simply tracks the high-water mark of what has been
/// written. `munmap` is the only thing that releases it, so the window slides
/// and the far end of a long page is never mapped at the same time as the near
/// end.
///
/// Access is sequential in both directions — frames are pasted in order and the
/// encoder reads in order — so a single window costs one remap per 64 MB.
///
/// Rows are top-down, RGBA8, premultiplied — matching the rest of the app.
public final class StitchCanvas {

    public let width: Int
    /// Rows reserved. Sparse, so reserving generously is nearly free.
    public let capacity: Int
    /// Highest row written, and therefore the height of the finished image.
    public private(set) var filledRows = 0

    /// Reported when a window could not be mapped; the affected rows read back
    /// blank rather than bringing the capture down.
    public private(set) var lastError: String?

    private let descriptor: Int32
    private let byteCount: Int
    private let url: URL
    private var closed = false

    private struct Window {
        let offset: Int
        let length: Int
        let base: UnsafeMutableRawPointer
    }

    private var window: Window?
    private let preferredWindowBytes: Int
    /// Handed out when a mapping fails, so callers always get a valid row.
    private var blankRow: [UInt8]

    public var bytesPerRow: Int { width * 4 }

    public init(width: Int, capacity: Int, windowBytes: Int = 64 * 1024 * 1024) throws {
        guard width > 0, capacity > 0 else { throw StitchCanvasError.invalidSize }
        self.width = width
        self.capacity = capacity
        self.byteCount = width * 4 * capacity
        self.blankRow = [UInt8](repeating: 0, count: width * 4)

        let pageSize = Int(getpagesize())
        // A window must be able to hold a whole frame, or a paste could never
        // be satisfied by one mapping.
        let minimum = max(windowBytes, width * 4 * 2048)
        self.preferredWindowBytes = ((minimum + pageSize - 1) / pageSize) * pageSize

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screensculpt-stitch-\(UUID().uuidString).raw")
        self.url = url

        descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw StitchCanvasError.couldNotAllocate(String(cString: strerror(errno)))
        }
        // Unlink immediately: the mapping keeps the file alive, and nothing is
        // left behind if the process is killed mid-capture.
        unlink(url.path)

        guard ftruncate(descriptor, off_t(byteCount)) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw StitchCanvasError.couldNotAllocate(message)
        }
    }

    deinit { release() }

    private func release() {
        guard !closed else { return }
        closed = true
        unmapWindow()
        close(descriptor)
    }

    private func unmapWindow() {
        guard let current = window else { return }
        munmap(current.base, current.length)
        window = nil
    }

    /// Map a region, replacing the current window if it does not already cover it.
    private func pointer(atByte offset: Int, length: Int) -> UnsafeMutableRawPointer? {
        guard offset >= 0, length > 0, offset + length <= byteCount else { return nil }

        if let current = window,
           offset >= current.offset,
           offset + length <= current.offset + current.length {
            return current.base.advanced(by: offset - current.offset)
        }

        unmapWindow()
        let pageSize = Int(getpagesize())
        let start = (offset / pageSize) * pageSize
        let span = min(max(preferredWindowBytes, offset + length - start), byteCount - start)

        let mapped = mmap(
            nil, span, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, off_t(start)
        )
        guard let mapped, mapped != MAP_FAILED else {
            lastError = String(cString: strerror(errno))
            return nil
        }
        window = Window(offset: start, length: span, base: mapped)
        return mapped.advanced(by: offset - start)
    }

    /// Write a frame's content region at a document row.
    ///
    /// Overlapping writes are intended, not merely tolerated. Each frame pastes
    /// its whole content region rather than only the rows believed to be new,
    /// so a row one frame trims too eagerly — a sticky band read a few pixels
    /// long, say — is simply written by the next frame. Overlaps carry the same
    /// pixels, so overwriting costs nothing and removes a class of off-by-a-few
    /// gaps that would otherwise accumulate down a long page.
    @discardableResult
    public func paste(_ image: CGImage, atRow row: Int, sticky: StickyBands = .none) -> Bool {
        let top = max(0, sticky.top)
        let bottom = max(0, sticky.bottom)
        let contentHeight = image.height - top - bottom
        guard contentHeight > 0, image.width == width else { return false }

        let destination = row + top
        guard destination >= 0 else { return false }
        let clipped = min(contentHeight, capacity - destination)
        guard clipped > 0 else { return false }

        guard let slice = pointer(
            atByte: destination * bytesPerRow, length: clipped * bytesPerRow
        ) else { return false }
        guard let context = CGContext(
            data: slice, width: width, height: clipped,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }

        // No flip. A bitmap context already lays its first memory row out as
        // the top of the image it produces, so the usual translate-and-invert
        // would turn every pasted frame upside down. (Verified against
        // CoreGraphics rather than assumed: the annotation renderer *does* flip,
        // but that is to put drawing geometry in top-left space, which is a
        // different question from where a blitted image lands.)
        //
        // The rect is offset by the bottom band, not the top: sliding the image
        // down by `bottom` pushes the footer past the end of the slice, leaving
        // the content region starting at memory row 0.
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(
                x: 0, y: -CGFloat(bottom),
                width: CGFloat(width), height: CGFloat(image.height)
            )
        )

        filledRows = max(filledRows, destination + clipped)
        return true
    }

    /// Stream the canvas to a PNG.
    ///
    /// The encoder reads strictly forward, so the window never moves backwards
    /// and a stitch far taller than memory writes at a flat cost.
    public func writePNG(to url: URL) throws {
        guard filledRows > 0 else { throw PNGEncodingError.invalidSize }
        try StreamingPNGEncoder.encode(width: width, height: filledRows, to: url) { row, yield in
            withRow(row) { yield($0) }
        }
    }

    /// Read-only access to one row, without copying.
    ///
    /// A failed mapping yields a blank row rather than trapping: losing a line
    /// of a long capture is recoverable, and taking the app down at the end of
    /// a two-minute scroll is not.
    public func withRow<T>(
        _ row: Int, _ body: (UnsafeRawBufferPointer) throws -> T
    ) rethrows -> T {
        precondition(row >= 0 && row < capacity, "row \(row) is outside the canvas")
        guard let start = pointer(atByte: row * bytesPerRow, length: bytesPerRow) else {
            return try blankRow.withUnsafeBytes { try body($0) }
        }
        return try body(UnsafeRawBufferPointer(start: start, count: bytesPerRow))
    }

    /// The finished stitch as an image — only for results small enough to hold.
    ///
    /// Returns nil past `ImageCodec.jpegMaxDimension`, which is also roughly
    /// where a single `CGImage` stops being a sensible thing to ask for. Long
    /// results go out through `StreamingPNGEncoder` instead.
    public func makeImage(pixelScale: PixelScale) -> RasterImage? {
        guard filledRows > 0, filledRows <= ImageCodec.jpegMaxDimension else { return nil }
        let length = filledRows * bytesPerRow
        var copy = [UInt8](repeating: 0, count: length)
        copy.withUnsafeMutableBytes { destination in
            for row in 0..<filledRows {
                withRow(row) { source in
                    destination.baseAddress!
                        .advanced(by: row * bytesPerRow)
                        .copyMemory(from: source.baseAddress!, byteCount: bytesPerRow)
                }
            }
        }
        guard
            let data = CFDataCreate(nil, copy, length),
            let provider = CGDataProvider(data: data),
            let image = CGImage(
                width: width, height: filledRows,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { return nil }
        return RasterImage(cgImage: image, pixelScale: pixelScale)
    }
}
