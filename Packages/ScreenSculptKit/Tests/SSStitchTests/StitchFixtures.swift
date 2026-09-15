// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

@testable import SSStitch

/// Deterministic PRNG.
///
/// `SystemRandomNumberGenerator` would make a failure unreproducible, which for
/// a correlator is the difference between a bug report and a shrug.
struct Xorshift: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// A tall synthetic page that frames are cut from.
///
/// Ground truth is known by construction, which is the only way to test a
/// stitcher without a window server: cut two frames a known distance apart and
/// the correct answer is that distance, exactly.
struct SyntheticDocument {

    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]

    init(width: Int, height: Int, fill: UInt8 = 250) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: fill, count: width * height)
    }

    /// Text-like rows: dark runs at varying positions, a blank gutter between.
    static func prose(
        width: Int = 900, height: Int = 6000, seed: UInt64 = 42, lineSpacing: Int = 28
    ) -> SyntheticDocument {
        var document = SyntheticDocument(width: width, height: height)
        var random = Xorshift(seed: seed)

        var y = 10
        while y + 12 < height {
            var x = Int.random(in: 8...40, using: &random)
            let limit = Int.random(in: (width / 3)...(width - 20), using: &random)
            while x < limit {
                let run = Int.random(in: 14...70, using: &random)
                let ink = UInt8(Int.random(in: 20...90, using: &random))
                document.fill(
                    x: x, y: y, width: min(run, limit - x), height: 12, value: ink
                )
                x += run + Int.random(in: 6...16, using: &random)
            }
            y += lineSpacing
        }
        return document
    }

    /// The pathological case: every row band identical to the one `period`
    /// above it. A list of equal-height cells looks exactly like this.
    static func periodic(
        width: Int = 900, height: Int = 6000, period: Int = 40
    ) -> SyntheticDocument {
        var document = SyntheticDocument(width: width, height: height)
        var random = Xorshift(seed: 7)
        var cell = [UInt8](repeating: 250, count: width * period)
        for y in 4..<(period - 8) {
            let start = Int.random(in: 10...60, using: &random)
            let end = Int.random(in: (width / 2)...(width - 30), using: &random)
            for x in start..<end { cell[y * width + x] = 60 }
        }
        for y in 0..<height {
            let source = (y % period) * width
            for x in 0..<width { document.pixels[y * width + x] = cell[source + x] }
        }
        return document
    }

    static func blank(width: Int = 900, height: Int = 6000) -> SyntheticDocument {
        SyntheticDocument(width: width, height: height)
    }

    mutating func fill(x: Int, y: Int, width runWidth: Int, height runHeight: Int, value: UInt8) {
        for row in y..<min(y + runHeight, height) {
            for column in x..<min(x + runWidth, width) {
                pixels[row * width + column] = value
            }
        }
    }

    /// Cut a viewport-sized frame at a document offset.
    func frame(at offset: Int, height frameHeight: Int) -> GrayFrame {
        var buffer = [UInt8](repeating: 250, count: width * frameHeight)
        for row in 0..<frameHeight {
            let source = offset + row
            guard source >= 0, source < height else { continue }
            for x in 0..<width {
                buffer[row * width + x] = pixels[source * width + x]
            }
        }
        return GrayFrame(width: width, height: frameHeight, pixels: buffer)
    }
}

extension GrayFrame {

    /// Stamp a fixed band over a frame, imitating a toolbar or tab bar that
    /// stays put while the content behind it scrolls.
    func withStickyBand(rows: Int, atTop: Bool, seed: UInt64 = 99) -> GrayFrame {
        var buffer = pixels
        var random = Xorshift(seed: seed)
        var band = [UInt8](repeating: 235, count: width * rows)
        for y in 2..<max(3, rows - 2) {
            let start = Int.random(in: 4...40, using: &random)
            let end = Int.random(in: (width / 3)...(width - 10), using: &random)
            for x in start..<end { band[y * width + x] = 40 }
        }
        for y in 0..<rows {
            let destination = atTop ? y : height - rows + y
            for x in 0..<width {
                buffer[destination * width + x] = band[y * width + x]
            }
        }
        return GrayFrame(width: width, height: height, pixels: buffer)
    }
}

/// Whether the full-scale memory gate runs.
///
/// It moves a gigabyte through hand-written byte loops, which an unoptimised
/// build turns into four minutes of nothing useful.
#if DEBUG
let runsAtFullScale = false
#else
let runsAtFullScale = true
#endif
