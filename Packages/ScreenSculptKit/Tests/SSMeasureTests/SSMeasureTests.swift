// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import Testing

@testable import SSMeasure

private func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBA8 { RGBA8(r: r, g: g, b: b) }

private let white = rgb(255, 255, 255)
private let black = rgb(0, 0, 0)

// MARK: - Colour spaces

@Suite("Colour spaces")
struct ColorSpaceTests {

    @Test("The sRGB transfer function round-trips")
    func transferRoundTrip() {
        for step in 0...255 {
            let value = Double(step) / 255
            let back = ColorSpaces.encode(ColorSpaces.linearise(value))
            #expect(abs(back - value) < 1e-9)
        }
    }

    @Test("The transfer function uses the piecewise curve, not a 2.2 power")
    func piecewiseNotApproximate() {
        // Near black the two diverge by enough to matter for contrast figures.
        let linear = ColorSpaces.linearise(0.03)
        #expect(abs(linear - 0.03 / 12.92) < 1e-12)
        #expect(abs(linear - pow(0.03, 2.2)) > 1e-4)
    }

    /// Reference values from Björn Ottosson's OKLab publication.
    @Test("OKLab matches published reference values")
    func oklabReference() {
        let whiteLab = ColorSpaces.oklab(linearR: 1, linearG: 1, linearB: 1)
        #expect(abs(whiteLab.l - 1.0) < 1e-3)
        #expect(abs(whiteLab.a) < 1e-3)
        #expect(abs(whiteLab.b) < 1e-3)

        // sRGB red.
        let red = ColorSpaces.oklch(r: 1, g: 0, b: 0)
        #expect(abs(red.l - 0.6279) < 2e-3)
        #expect(abs(red.c - 0.2577) < 2e-3)
        #expect(abs(red.h - 29.23) < 0.5)
    }

    @Test("OKLCh reports no hue for greys, rather than a residual angle")
    func greyHasNoHue() {
        let grey = ColorSpaces.oklch(r: 0.5, g: 0.5, b: 0.5)
        #expect(grey.c < 1e-6)
        #expect(grey.h == 0)
    }

    @Test("OKLCh lightness is perceptually ordered")
    func lightnessOrdering() {
        let dark = ColorSpaces.oklch(r: 0.2, g: 0.2, b: 0.2).l
        let mid = ColorSpaces.oklch(r: 0.5, g: 0.5, b: 0.5).l
        let light = ColorSpaces.oklch(r: 0.9, g: 0.9, b: 0.9).l
        #expect(dark < mid)
        #expect(mid < light)
    }

    @Test("HSL handles the primaries and grey")
    func hslPrimaries() {
        let red = ColorSpaces.hsl(r: 1, g: 0, b: 0)
        #expect(abs(red.h) < 1e-9)
        #expect(abs(red.s - 1) < 1e-9)
        #expect(abs(red.l - 0.5) < 1e-9)

        let green = ColorSpaces.hsl(r: 0, g: 1, b: 0)
        #expect(abs(green.h - 120) < 1e-9)

        let blue = ColorSpaces.hsl(r: 0, g: 0, b: 1)
        #expect(abs(blue.h - 240) < 1e-9)

        let grey = ColorSpaces.hsl(r: 0.5, g: 0.5, b: 0.5)
        #expect(grey.s == 0)
    }
}

// MARK: - Contrast

@Suite("WCAG 2 contrast")
struct WCAGTests {

    @Test("Black on white is exactly 21:1")
    func extremes() {
        #expect(abs(Contrast.wcag2(foreground: black, background: white) - 21) < 1e-6)
        #expect(abs(Contrast.wcag2(foreground: white, background: black) - 21) < 1e-6)
    }

    @Test("A colour against itself is 1:1")
    func identity() {
        #expect(abs(Contrast.wcag2(foreground: white, background: white) - 1) < 1e-9)
        #expect(abs(Contrast.wcag2(foreground: rgb(80, 120, 200),
                                   background: rgb(80, 120, 200)) - 1) < 1e-9)
    }

    @Test("The ratio is symmetric")
    func symmetric() {
        let a = rgb(30, 90, 140), b = rgb(240, 210, 60)
        #expect(
            abs(Contrast.wcag2(foreground: a, background: b)
                - Contrast.wcag2(foreground: b, background: a)) < 1e-12
        )
    }

    /// Known figure: #767676 on white is the canonical "just passes AA" grey.
    @Test("Mid grey on white lands just above 4.5:1")
    func knownMidGrey() {
        let ratio = Contrast.wcag2(foreground: rgb(0x76, 0x76, 0x76), background: white)
        #expect(ratio > 4.5)
        #expect(ratio < 4.6)
        #expect(Contrast.wcagLevel(ratio) == .aa)
    }

    @Test("Levels are graded correctly")
    func levels() {
        #expect(Contrast.wcagLevel(21) == .aaa)
        #expect(Contrast.wcagLevel(7.0) == .aaa)
        #expect(Contrast.wcagLevel(4.5) == .aa)
        #expect(Contrast.wcagLevel(3.0) == .aaLarge)
        #expect(Contrast.wcagLevel(2.9) == .fail)
        // Large text has lower thresholds.
        #expect(Contrast.wcagLevel(3.0, largeText: true) == .aa)
    }
}

@Suite("APCA contrast")
struct APCATests {

    /// Reference values for APCA-W3 0.1.9. These are the two figures every
    /// implementation is checked against.
    @Test("Black on white is Lc 106")
    func blackOnWhite() {
        let lc = Contrast.apca(text: black, background: white)
        #expect(abs(lc - 106.04) < 0.1, "got \(lc)")
    }

    @Test("White on black is Lc −108, and the sign carries the polarity")
    func whiteOnBlack() {
        let lc = Contrast.apca(text: white, background: black)
        #expect(abs(lc - (-107.88)) < 0.1, "got \(lc)")
        // Negative means light text on a dark background — APCA is deliberately
        // asymmetric, unlike WCAG 2.
        #expect(lc < 0)
    }

    @Test("APCA is asymmetric where WCAG 2 is not")
    func asymmetry() {
        let forward = Contrast.apca(text: black, background: white)
        let reverse = Contrast.apca(text: white, background: black)
        #expect(abs(forward) != abs(reverse))
    }

    @Test("Identical colours give zero")
    func identity() {
        #expect(Contrast.apca(text: white, background: white) == 0)
        #expect(Contrast.apca(text: rgb(100, 100, 100), background: rgb(100, 100, 100)) == 0)
    }

    @Test("Near-identical colours are clipped to zero rather than reported as tiny")
    func lowClip() {
        // Below the clip threshold the figure is not meaningful, and printing
        // "Lc 3" invites someone to treat it as a real measurement.
        let lc = Contrast.apca(text: rgb(128, 128, 128), background: rgb(132, 132, 132))
        #expect(lc == 0)
    }

    @Test("Verdicts are graded by magnitude, ignoring polarity")
    func verdicts() {
        #expect(Contrast.apcaVerdict(106) == "Any text")
        #expect(Contrast.apcaVerdict(-106) == "Any text")
        #expect(Contrast.apcaVerdict(80) == "Body text")
        #expect(Contrast.apcaVerdict(65) == "Large text only")
        #expect(Contrast.apcaVerdict(10) == "Invisible")
    }

    @Test("The implemented revision is stated")
    func revisionStated() {
        // Coefficients changed between drafts; a reader comparing against
        // another revision needs to know which one this is.
        #expect(Contrast.apcaRevision.contains("0.1.9"))
    }
}

// MARK: - Formatting

@Suite("Colour formatting")
struct FormatterTests {

    @Test("Every format produces something sensible for a known colour")
    func formats() {
        let colour = rgb(0x1E, 0x90, 0xFF)  // dodger blue
        #expect(ColorFormatter.string(for: colour, as: .hex) == "#1E90FF")
        #expect(ColorFormatter.string(for: colour, as: .hexPlain) == "1E90FF")
        #expect(ColorFormatter.string(for: colour, as: .rgb) == "rgb(30, 144, 255)")
        #expect(ColorFormatter.string(for: colour, as: .hsl).hasPrefix("hsl("))
        #expect(ColorFormatter.string(for: colour, as: .oklch).hasPrefix("oklch("))
        #expect(ColorFormatter.string(for: colour, as: .swiftUI).hasPrefix("Color(red:"))
    }

    @Test("Hex is upper case and zero-padded")
    func hexPadding() {
        #expect(ColorFormatter.string(for: rgb(1, 2, 3), as: .hex) == "#010203")
        #expect(ColorFormatter.string(for: black, as: .hex) == "#000000")
        #expect(ColorFormatter.string(for: white, as: .hex) == "#FFFFFF")
    }

    @Test("Whole numbers do not print a trailing .0")
    func noTrailingZero() {
        let text = ColorFormatter.string(for: white, as: .oklch)
        #expect(!text.contains(".0 "))
    }
}

// MARK: - Sampling

@MainActor
private func buffer(width: Int = 100, height: Int = 100,
                    paint: (CGContext) -> Void) -> PixelBuffer {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    paint(context)
    return PixelBuffer(
        RasterImage(cgImage: context.makeImage()!, pixelScale: .x1)
    )!
}

@Suite("Sampling")
@MainActor
struct SamplingTests {

    @Test("A pixel reads back the exact stored value")
    func exactPixel() {
        let pixels = buffer { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(
                CGColor(srgbRed: 30.0 / 255, green: 144.0 / 255, blue: 255.0 / 255, alpha: 1)
            )
            context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        }
        // CGContext fills bottom-up; PixelBuffer indexes top-down. A CG rect at
        // y 10…30 of a 100px image therefore lands at image rows 70…90.
        let sampled = pixels.color(x: 20, y: 80)
        // Exactness is the whole promise of a colour picker.
        #expect(sampled?.r == 30)
        #expect(sampled?.g == 144)
        #expect(sampled?.b == 255)
    }

    @Test("Sampling outside the image returns nothing")
    func outOfBounds() {
        let pixels = buffer { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        #expect(pixels.color(x: -1, y: 5) == nil)
        #expect(pixels.color(x: 500, y: 5) == nil)
    }

    @Test("Average colour is computed in linear space")
    func averageIsLinear() {
        // Half black, half white. Averaging gamma values would give ~128;
        // averaging correctly in linear space gives ~188.
        let pixels = buffer { context in
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        }
        let average = ColorSampler.averageColor(
            in: pixels, rect: ImageRect(x: 0, y: 0, width: 100, height: 100)
        )
        #expect(average != nil)
        #expect(average!.r > 180, "got \(average!.r) — looks like a gamma-space average")
        #expect(average!.r < 195)
    }

    @Test("Text colour finds the dark stroke, not the antialiased fringe")
    func textColour() {
        let pixels = buffer { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            // A dark bar standing in for a glyph stroke.
            context.setFillColor(
                CGColor(srgbRed: 0.1, green: 0.1, blue: 0.5, alpha: 1)
            )
            context.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
        }
        let colour = ColorSampler.textColor(
            in: pixels, around: ImagePoint(x: 50, y: 50), radius: 10
        )
        #expect(colour != nil)
        #expect(colour!.b > colour!.r, "should have found the blue-ish stroke")
    }
}

// MARK: - Ruler

@Suite("Ruler and auto-fit")
@MainActor
struct RulerTests {

    /// A white field with one black bar from x=30 to x=70.
    private func barImage() -> PixelBuffer {
        buffer { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 30, y: 0, width: 40, height: 100))
        }
    }

    @Test("Measuring inside a run reports its full width")
    func measuresRun() {
        let reading = RulerEngine.measure(
            from: ImagePoint(x: 50, y: 50), axis: .horizontal, in: barImage()
        )
        #expect(reading != nil)
        #expect(reading!.length == ImagePx(40), "got \(reading!.length)")
    }

    @Test("Measuring in the margin reports the gap beside the element")
    func measuresGap() {
        let reading = RulerEngine.measure(
            from: ImagePoint(x: 10, y: 50), axis: .horizontal, in: barImage()
        )
        #expect(reading!.length == ImagePx(30), "got \(reading!.length)")
    }

    @Test("The next edge is found in both directions")
    func findsEdges() {
        let pixels = barImage()
        let rightward = RulerEngine.nextEdge(
            from: ImagePoint(x: 10, y: 50), axis: .horizontal, forward: true, in: pixels
        )
        #expect(rightward == ImagePx(30))

        let leftward = RulerEngine.nextEdge(
            from: ImagePoint(x: 90, y: 50), axis: .horizontal, forward: false, in: pixels
        )
        #expect(leftward == ImagePx(69))
    }

    @Test("Scanning off the edge of the image reports nothing")
    func noEdgeFound() {
        let plain = buffer { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        #expect(
            RulerEngine.nextEdge(
                from: ImagePoint(x: 50, y: 50), axis: .horizontal, forward: true, in: plain
            ) == nil
        )
    }

    @Test("Auto-fit snaps a rough marquee onto the element")
    func autoFit() {
        let pixels = buffer { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            // CGContext is bottom-up, so this lands at image y = 30…70.
            context.fill(CGRect(x: 30, y: 30, width: 40, height: 40))
        }
        let fitted = ElementFitter.fit(
            ImageRect(x: 35, y: 35, width: 30, height: 30), in: pixels
        )
        #expect(abs(fitted.minX.value - 30) <= 1, "left landed at \(fitted.minX)")
        #expect(abs(fitted.maxX.value - 70) <= 1, "right landed at \(fitted.maxX)")
    }

    @Test("An edge with no confident boundary is left exactly where it was")
    func autoFitLeavesUncertainEdges() {
        // A partial snap beats a confident wrong one. On a blank field nothing
        // should move at all.
        let plain = buffer { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let original = ImageRect(x: 20, y: 20, width: 40, height: 40)
        #expect(ElementFitter.fit(original, in: plain) == original)
    }
}
