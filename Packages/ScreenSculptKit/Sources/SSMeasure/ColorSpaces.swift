// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

/// Hue, saturation, lightness. Hue in degrees, the rest 0…1.
public struct HSL: Hashable, Sendable {
    public var h: Double, s: Double, l: Double
    public init(h: Double, s: Double, l: Double) { self.h = h; self.s = s; self.l = l }
}

/// Perceptual lightness, chroma and hue. Hue in degrees.
public struct OKLCh: Hashable, Sendable {
    public var l: Double, c: Double, h: Double
    public init(l: Double, c: Double, h: Double) { self.l = l; self.c = c; self.h = h }
}

/// Opponent-axis form of OKLCh, kept separate because the conversion goes
/// through it and tests check it directly.
public struct OKLab: Hashable, Sendable {
    public var l: Double, a: Double, b: Double
    public init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }
}

/// Conversions between the colour spaces the readout offers.
///
/// Hand-rolled rather than routed through Core Image or ColorSync, because a
/// pixel tool must report the numbers that are *in the file*. A colour-managed
/// pipeline would give perceptually reasonable but different values, and
/// "different" is the one thing a colour picker may not be.
public enum ColorSpaces {

    // MARK: - sRGB transfer function

    /// sRGB gamma → linear. The piecewise curve, not an approximate 2.2 power.
    public static func linearise(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// Linear → sRGB gamma.
    public static func encode(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }

    // MARK: - HSL

    public static func hsl(r: Double, g: Double, b: Double) -> HSL {
        let maxValue = max(r, g, b)
        let minValue = min(r, g, b)
        let lightness = (maxValue + minValue) / 2
        let delta = maxValue - minValue

        guard delta > 1e-9 else { return HSL(h: 0, s: 0, l: lightness) }

        let saturation = lightness > 0.5
            ? delta / (2 - maxValue - minValue)
            : delta / (maxValue + minValue)

        var hue: Double
        if maxValue == r {
            hue = (g - b) / delta + (g < b ? 6 : 0)
        } else if maxValue == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        return HSL(h: hue * 60, s: saturation, l: lightness)
    }

    // MARK: - OKLab / OKLCh

    /// Linear sRGB → OKLab, per Björn Ottosson's published matrices.
    ///
    /// OKLCh is worth having because its lightness is perceptually uniform: two
    /// colours with the same L look equally bright, which HSL's L emphatically
    /// does not give you.
    public static func oklab(linearR: Double, linearG: Double, linearB: Double) -> OKLab {
        let l = 0.4122214708 * linearR + 0.5363325363 * linearG + 0.0514459929 * linearB
        let m = 0.2119034982 * linearR + 0.6806995451 * linearG + 0.1073969566 * linearB
        let s = 0.0883024619 * linearR + 0.2817188376 * linearG + 0.6299787005 * linearB

        let lRoot = cbrt(l), mRoot = cbrt(m), sRoot = cbrt(s)

        return OKLab(
            l: 0.2104542553 * lRoot + 0.7936177850 * mRoot - 0.0040720468 * sRoot,
            a: 1.9779984951 * lRoot - 2.4285922050 * mRoot + 0.4505937099 * sRoot,
            b: 0.0259040371 * lRoot + 0.7827717662 * mRoot - 0.8086757660 * sRoot
        )
    }

    /// Gamma sRGB (0…1) → OKLCh, with hue in degrees.
    public static func oklch(r: Double, g: Double, b: Double) -> OKLCh {
        let lab = oklab(linearR: linearise(r), linearG: linearise(g), linearB: linearise(b))
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        var hue = atan2(lab.b, lab.a) * 180 / .pi
        if hue < 0 { hue += 360 }
        // Hue is meaningless at zero chroma, and reporting a residual angle for
        // grey reads as noise.
        return OKLCh(l: lab.l, c: chroma, h: chroma < 1e-6 ? 0 : hue)
    }

    // MARK: - Luminance

    /// WCAG 2.x relative luminance from gamma-encoded sRGB.
    public static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        0.2126 * linearise(r) + 0.7152 * linearise(g) + 0.0722 * linearise(b)
    }

    /// APCA's estimated screen luminance.
    ///
    /// Deliberately *not* the WCAG figure: APCA uses a simple 2.4 power curve
    /// with its own coefficients rather than the piecewise sRGB function.
    public static func apcaLuminance(r: Double, g: Double, b: Double) -> Double {
        0.2126729 * pow(r, 2.4) + 0.7151522 * pow(g, 2.4) + 0.0721750 * pow(b, 2.4)
    }
}
