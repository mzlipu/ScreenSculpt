// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SSGeometry
import Testing

@testable import SSStitch

// MARK: - Helpers

/// A solid RGBA image, so a paste can be checked by reading one pixel.
private func solidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(
        red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1
    )
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Two horizontal halves, which makes a vertical flip immediately visible.
private func splitImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // CoreGraphics is bottom-up here, so this fills the image's TOP half red.
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
    return context.makeImage()!
}

private func canvasPixel(_ canvas: StitchCanvas, x: Int, y: Int) -> [UInt8] {
    canvas.withRow(y) { bytes in
        let offset = x * 4
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
    }
}

/// Resident memory, for the size test.
private func residentBytes() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
}

// MARK: - Canvas

@Suite("Stitch canvas")
struct StitchCanvasTests {

    @Test("A pasted frame keeps its orientation")
    func pasteIsTopDown() throws {
        let canvas = try StitchCanvas(width: 40, capacity: 100)
        canvas.paste(splitImage(width: 40, height: 20), atRow: 0)

        // Red is the image's top half, so it must land in the canvas's first rows.
        #expect(canvasPixel(canvas, x: 5, y: 2)[0] > 200, "top row is not the image's top")
        #expect(canvasPixel(canvas, x: 5, y: 17)[2] > 200, "bottom row is not the image's bottom")
    }

    @Test("Frames stack at their document rows")
    func stacksFrames() throws {
        let canvas = try StitchCanvas(width: 40, capacity: 200)
        canvas.paste(solidImage(width: 40, height: 30, r: 255, g: 0, b: 0), atRow: 0)
        canvas.paste(solidImage(width: 40, height: 30, r: 0, g: 255, b: 0), atRow: 30)

        #expect(canvasPixel(canvas, x: 1, y: 10)[0] > 200)
        #expect(canvasPixel(canvas, x: 1, y: 40)[1] > 200)
        #expect(canvas.filledRows == 60)
    }

    @Test("Sticky bands are not pasted")
    func skipsStickyBands() throws {
        let canvas = try StitchCanvas(width: 40, capacity: 200)
        let frame = splitImage(width: 40, height: 40)
        // Drop the red top half as though it were a fixed header.
        canvas.paste(frame, atRow: 0, sticky: StickyBands(top: 20, bottom: 0))

        #expect(canvas.filledRows == 40, "content should sit below the skipped band")
        #expect(canvasPixel(canvas, x: 5, y: 25)[2] > 200, "expected the blue half")
    }

    /// Over-reading a sticky band must not punch a hole, because the next frame
    /// covers those rows. This is what lets the detector err on the safe side.
    @Test("An overlapping paste overwrites rather than leaving a gap")
    func overlapsAreSafe() throws {
        let canvas = try StitchCanvas(width: 40, capacity: 200)
        canvas.paste(solidImage(width: 40, height: 50, r: 255, g: 0, b: 0), atRow: 0)
        canvas.paste(solidImage(width: 40, height: 50, r: 0, g: 255, b: 0), atRow: 30)

        for row in 0..<80 {
            let pixel = canvasPixel(canvas, x: 1, y: row)
            #expect(pixel[3] == 255, "row \(row) was never written")
        }
        #expect(canvasPixel(canvas, x: 1, y: 40)[1] > 200, "the later frame should win")
    }

    @Test("A frame of the wrong width is refused")
    func refusesMismatchedWidth() throws {
        let canvas = try StitchCanvas(width: 40, capacity: 100)
        #expect(!canvas.paste(solidImage(width: 39, height: 10, r: 0, g: 0, b: 0), atRow: 0))
    }

    @Test("Pasting past the end is clipped, not fatal")
    func clipsAtCapacity() throws {
        let canvas = try StitchCanvas(width: 40, capacity: 50)
        #expect(canvas.paste(solidImage(width: 40, height: 30, r: 1, g: 2, b: 3), atRow: 40))
        #expect(canvas.filledRows == 50)
    }

    @Test("A zero-sized canvas is rejected")
    func rejectsEmpty() {
        #expect(throws: StitchCanvasError.self) { try StitchCanvas(width: 0, capacity: 10) }
    }
}

// MARK: - Encoder

@Suite("Streaming PNG encoder")
struct StreamingPNGEncoderTests {

    private func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The encoder writes the container, the DEFLATE stream, the zlib wrapper
    /// and both checksums by hand. Only the system decoder can say whether all
    /// four are right, so it is the test.
    @Test("The output is a PNG the system can read back")
    func roundTrip() throws {
        let canvas = try StitchCanvas(width: 64, capacity: 40)
        canvas.paste(splitImage(width: 64, height: 40), atRow: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-encoder-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try StreamingPNGEncoder.encode(
            width: canvas.width, height: canvas.filledRows, to: url
        ) { row, yield in
            canvas.withRow(row) { yield($0) }
        }

        let decoded = try #require(decode(url), "the file was not a readable PNG")
        #expect(decoded.width == 64)
        #expect(decoded.height == 40)
    }

    @Test("Decoded pixels match what was written")
    func pixelsSurvive() throws {
        let width = 48
        let height = 32
        let canvas = try StitchCanvas(width: width, capacity: height)
        canvas.paste(solidImage(width: width, height: 16, r: 200, g: 40, b: 10), atRow: 0)
        canvas.paste(solidImage(width: width, height: 16, r: 10, g: 60, b: 220), atRow: 16)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-encoder-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try StreamingPNGEncoder.encode(width: width, height: height, to: url) { row, yield in
            canvas.withRow(row) { yield($0) }
        }

        let decoded = try #require(decode(url))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        }

        // A bitmap context's row 0 in memory is the image's top row, so these
        // read in the same order the canvas was written.
        let topRow = 4 * width * 4
        #expect(abs(Int(pixels[topRow]) - 200) <= 2, "red band lost its red channel")
        #expect(abs(Int(pixels[topRow + 1]) - 40) <= 2)
        let bottomRow = 28 * width * 4
        #expect(abs(Int(pixels[bottomRow]) - 10) <= 2, "blue band kept too much red")
        #expect(abs(Int(pixels[bottomRow + 2]) - 220) <= 2)
    }

    @Test("A zero-height image is refused rather than written empty")
    func rejectsEmpty() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ss-empty.png")
        #expect(throws: PNGEncodingError.self) {
            try StreamingPNGEncoder.encode(width: 10, height: 0, to: url) { _, _ in }
        }
    }

    /// Cheap proof of the mechanism: write far more than the window holds and
    /// watch resident memory stay near the window size.
    ///
    /// Shrinking the window rather than growing the image is what keeps this
    /// affordable in a debug build, and it tests the same thing — whether the
    /// canvas unmaps what it has finished with.
    @Test("Writing past the window does not accumulate resident memory")
    func windowSlides() throws {
        let width = 600
        let height = 200_000
        let windowBytes = 8 * 1024 * 1024
        let totalBytes = width * 4 * height          // 480 MB

        let canvas = try StitchCanvas(
            width: width, capacity: height, windowBytes: windowBytes
        )
        let band = solidImage(width: width, height: 500, r: 12, g: 200, b: 90)
        // Paste once before measuring: the image, the first mapping and the
        // test's own allocations should not be attributed to the canvas. The
        // total is then large enough that what remains is unambiguous.
        canvas.paste(band, atRow: 0)

        let before = residentBytes()
        for row in stride(from: 500, to: height, by: 500) {
            canvas.paste(band, atRow: row)
        }
        let growth = residentBytes() - before

        #expect(canvas.filledRows == height)
        #expect(
            growth < totalBytes / 4,
            "grew \(growth / 1_048_576) MB writing \(totalBytes / 1_048_576) MB"
        )
        #expect(canvas.lastError == nil)
    }

    /// The plan's memory gate, at full scale: 200,000 rows of 1200 pixels is
    /// 960 MB of RGBA that must never be resident at once.
    ///
    /// Release only. The encoder's filter, Adler-32 and CRC passes are
    /// byte-at-a-time loops, and a debug build runs them roughly ninety times
    /// slower — four minutes of measuring the optimiser's absence rather than
    /// the design. `swift test -c release` runs it.
    @Test(
        "A 200,000-row stitch encodes without holding the image in memory",
        .enabled(if: runsAtFullScale)
    )
    func longStitchStaysSmall() throws {
        let width = 1200
        let height = 200_000
        let canvas = try StitchCanvas(width: width, capacity: height)

        let before = residentBytes()
        let band = solidImage(width: width, height: 1000, r: 90, g: 140, b: 210)
        for row in stride(from: 0, to: height, by: 1000) {
            canvas.paste(band, atRow: row)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-long-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try canvas.writePNG(to: url)

        let growth = residentBytes() - before
        #expect(canvas.filledRows == height)
        #expect(
            growth < 400 * 1024 * 1024,
            "resident memory grew by \(growth / 1_048_576) MB stitching a 200,000-row page"
        )

        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 0)
    }
}
