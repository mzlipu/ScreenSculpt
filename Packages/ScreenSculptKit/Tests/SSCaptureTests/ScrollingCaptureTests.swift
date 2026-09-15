// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import Testing

@testable import SSCapture

// MARK: - Fixtures

/// A tall page frames are cut from, built without a window server.
nonisolated private struct Page {
    let width = 600
    let height = 12_000
    private let pixels: [UInt8]

    init() {
        var buffer = [UInt8](repeating: 250, count: 600 * 12_000)
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func random(_ range: ClosedRange<Int>) -> Int {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return range.lowerBound + Int(seed % UInt64(range.count))
        }
        var y = 8
        while y + 12 < 12_000 {
            var x = random(8...40)
            let limit = random(240...560)
            while x < limit {
                let run = random(12...60)
                let ink = UInt8(random(20...90))
                for row in y..<(y + 12) {
                    for column in x..<min(x + run, limit) { buffer[row * 600 + column] = ink }
                }
                x += run + random(6...16)
            }
            y += 26
        }
        pixels = buffer
    }

    func image(at offset: Int, height frameHeight: Int) -> CGImage {
        var rgba = [UInt8](repeating: 255, count: width * frameHeight * 4)
        for row in 0..<frameHeight {
            let source = offset + row
            for x in 0..<width {
                let value = source >= 0 && source < height ? pixels[source * width + x] : 250
                let index = (row * width + x) * 4
                rgba[index] = value
                rgba[index + 1] = value
                rgba[index + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(
            width: width, height: frameHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }
}

/// Replays a scripted sequence of scroll positions.
///
/// Manual mode watches the screen and commits a frame once it stops changing,
/// so a script is exactly the right shape for it: each entry is what the next
/// look at the page would show, repeats and all.
@MainActor
private final class ScriptedCaptureService: CaptureService {

    private let page: Page
    private let offsets: [Int]
    private let frameHeight: Int
    private var index = 0

    init(offsets: [Int], frameHeight: Int) {
        self.page = Page()
        self.offsets = offsets
        self.frameHeight = frameHeight
    }

    /// How many times the page has been looked at, which is how a test can tell
    /// a capture that stopped from one that merely ran out of script.
    var consumed: Int { index }

    func capture(_ request: CaptureRequest) async throws -> CaptureResult {
        let offset = offsets[min(index, offsets.count - 1)]
        index += 1
        let image = RasterImage(
            cgImage: page.image(at: offset, height: frameHeight), pixelScale: .x1
        )
        return CaptureResult(
            image: image,
            provenance: CaptureProvenance(
                sourceRect: nil, pixelScale: .x1, displays: [],
                sourceDisplayID: nil, spansMixedScales: false
            )
        )
    }
}

private func fastOptions() -> ScrollingCaptureController.Options {
    var options = ScrollingCaptureController.Options()
    options.manualPollInterval = .milliseconds(1)
    options.manualIdleTimeout = .milliseconds(20)
    options.manualStartTimeout = .milliseconds(60)
    return options
}

private let region = ScreenRect(
    x: LogicalPt(0), y: LogicalPt(0), width: LogicalPt(600), height: LogicalPt(700)
)

// MARK: - Tests

@Suite("Manual scrolling capture")
@MainActor
struct ManualScrollingCaptureTests {

    /// Each position has to be seen twice before it counts: once to notice the
    /// change, once to confirm the page has stopped.
    private func script(_ positions: [Int], settled: Int = 2) -> [Int] {
        positions.flatMap { Array(repeating: $0, count: settled) }
    }

    @Test("Frames the user scrolls past are stitched")
    func stitchesUserScrolling() async throws {
        let offsets = [0, 400, 800, 1200, 1600]
        let service = ScriptedCaptureService(
            offsets: script(offsets) + Array(repeating: 1600, count: 400), frameHeight: 700
        )
        let controller = ScrollingCaptureController(captureService: service)

        let result = try await controller.captureManually(area: region, options: fastOptions())

        #expect(result.frameCount == offsets.count, "captured \(result.frameCount) frames")
        #expect(result.offsets == [400, 400, 400, 400], "measured \(result.offsets)")
        #expect(result.rows == 1600 + 700)
    }

    /// A frame caught mid-scroll must not be committed, or every later offset
    /// is measured from a smear.
    @Test("A page still moving is not committed")
    func waitsForTheScrollToStop() async throws {
        // Each position appears once — never twice in a row — so nothing ever
        // settles and nothing should be accepted.
        let service = ScriptedCaptureService(
            offsets: (0..<60).map { $0 * 37 }, frameHeight: 700
        )
        let controller = ScrollingCaptureController(captureService: service)

        await #expect(throws: ScrollingCaptureError.self) {
            try await controller.captureManually(area: region, options: fastOptions())
        }
    }

    @Test("A page that never moves reports that, rather than a one-frame stitch")
    func requiresMovement() async throws {
        let service = ScriptedCaptureService(
            offsets: Array(repeating: 0, count: 200), frameHeight: 700
        )
        let controller = ScrollingCaptureController(captureService: service)

        await #expect(throws: ScrollingCaptureError.self) {
            try await controller.captureManually(area: region, options: fastOptions())
        }
    }

    @Test("Scrolling stops the capture once the page sits still")
    func idleEndsTheCapture() async throws {
        let service = ScriptedCaptureService(
            offsets: script([0, 350, 700]) + Array(repeating: 700, count: 500),
            frameHeight: 700
        )
        let controller = ScrollingCaptureController(captureService: service)

        let result = try await controller.captureManually(area: region, options: fastOptions())
        #expect(result.frameCount == 3)
        // It must stop on its own rather than running to the frame ceiling.
        #expect(service.consumed < 100, "kept polling \(service.consumed) times")
    }

    @Test("Requesting Done ends the capture immediately")
    func honoursStopRequest() async throws {
        let service = ScriptedCaptureService(
            offsets: script([0, 300, 600, 900, 1200]), frameHeight: 700
        )
        let controller = ScrollingCaptureController(captureService: service)
        var polls = 0

        let result = try await controller.captureManually(
            area: region, options: fastOptions(),
            shouldStop: {
                polls += 1
                return polls > 5
            }
        )
        #expect(result.frameCount >= 2)
        #expect(result.frameCount < 5, "should have stopped early")
    }

    @Test("A region too short to overlap is refused up front")
    func refusesShortRegion() async throws {
        let service = ScriptedCaptureService(offsets: [0], frameHeight: 100)
        let controller = ScrollingCaptureController(captureService: service)
        let tiny = ScreenRect(
            x: LogicalPt(0), y: LogicalPt(0), width: LogicalPt(600), height: LogicalPt(100)
        )
        await #expect(throws: ScrollingCaptureError.self) {
            try await controller.captureManually(area: tiny, options: fastOptions())
        }
    }

    /// Scrolling faster than a frame height leaves no overlap, and nothing can
    /// recover the gap. It has to be reported, with advice that works.
    @Test("Scrolling past a whole frame is reported, not stitched wrong")
    func refusesOverlaplessJump() async throws {
        let service = ScriptedCaptureService(
            offsets: script([0, 2400]) + Array(repeating: 2400, count: 200), frameHeight: 700
        )
        let controller = ScrollingCaptureController(captureService: service)

        do {
            let result = try await controller.captureManually(area: region, options: fastOptions())
            #expect(result.frameCount == 1, "a frame with no overlap was accepted")
        } catch let error as ScrollingCaptureError {
            #expect("\(error.localizedDescription)".contains("scroll"))
        }
    }
}
