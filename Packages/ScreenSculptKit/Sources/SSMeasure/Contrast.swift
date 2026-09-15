// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSImaging

/// Contrast between a foreground and a background colour.
public enum Contrast {

    // MARK: - WCAG 2.x

    /// Ratio from 1:1 to 21:1.
    ///
    /// The familiar figure, and the one accessibility audits still cite, but it
    /// is a poor model of perceived contrast — it over-rates light-on-dark and
    /// under-rates mid-tone pairs. Reported alongside APCA rather than instead
    /// of it.
    public static func wcag2(foreground: RGBA8, background: RGBA8) -> Double {
        let lighter = max(
            ColorSpaces.relativeLuminance(
                r: Double(foreground.r) / 255,
                g: Double(foreground.g) / 255,
                b: Double(foreground.b) / 255
            ),
            ColorSpaces.relativeLuminance(
                r: Double(background.r) / 255,
                g: Double(background.g) / 255,
                b: Double(background.b) / 255
            )
        )
        let darker = min(
            ColorSpaces.relativeLuminance(
                r: Double(foreground.r) / 255,
                g: Double(foreground.g) / 255,
                b: Double(foreground.b) / 255
            ),
            ColorSpaces.relativeLuminance(
                r: Double(background.r) / 255,
                g: Double(background.g) / 255,
                b: Double(background.b) / 255
            )
        )
        return (lighter + 0.05) / (darker + 0.05)
    }

    public enum WCAGLevel: String, Sendable {
        case fail = "Fail"
        case aaLarge = "AA Large"
        case aa = "AA"
        case aaa = "AAA"
    }

    /// Level reached for body text. Large text has lower thresholds (3.0 / 4.5).
    public static func wcagLevel(_ ratio: Double, largeText: Bool = false) -> WCAGLevel {
        if largeText {
            return switch ratio {
            case 4.5...: .aaa
            case 3.0...: .aa
            default: .fail
            }
        }
        return switch ratio {
        case 7.0...: .aaa
        case 4.5...: .aa
        case 3.0...: .aaLarge
        default: .fail
        }
    }

    // MARK: - APCA

    /// APCA lightness contrast (Lc), per APCA-W3 revision 0.1.9.
    ///
    /// Signed: positive means dark text on a light background, negative the
    /// reverse. The magnitude is what matters — roughly, Lc 60 is the floor for
    /// body text and Lc 90 for thin or small type.
    ///
    /// The revision matters and is worth stating in the UI: the coefficients
    /// have changed between drafts, and a reader comparing against a different
    /// revision will get different numbers.
    public static let apcaRevision = "APCA-W3 0.1.9"

    public static func apca(text: RGBA8, background: RGBA8) -> Double {
        let normBG = 0.56, normTXT = 0.57, revTXT = 0.62, revBG = 0.65
        let blackThreshold = 0.022, blackClamp = 1.414
        let scale = 1.14, offset = 0.027
        let deltaYMin = 0.0005, lowClip = 0.1

        func clamped(_ y: Double) -> Double {
            // Soft-clamp near black: below the threshold, real displays flare
            // and the raw luminance overstates the difference.
            y > blackThreshold ? y : y + pow(blackThreshold - y, blackClamp)
        }

        let textY = clamped(ColorSpaces.apcaLuminance(
            r: Double(text.r) / 255, g: Double(text.g) / 255, b: Double(text.b) / 255
        ))
        let backgroundY = clamped(ColorSpaces.apcaLuminance(
            r: Double(background.r) / 255,
            g: Double(background.g) / 255,
            b: Double(background.b) / 255
        ))

        guard abs(backgroundY - textY) >= deltaYMin else { return 0 }

        let contrast: Double
        if backgroundY > textY {
            let sapc = (pow(backgroundY, normBG) - pow(textY, normTXT)) * scale
            contrast = sapc < lowClip ? 0 : sapc - offset
        } else {
            let sapc = (pow(backgroundY, revBG) - pow(textY, revTXT)) * scale
            contrast = sapc > -lowClip ? 0 : sapc + offset
        }
        return contrast * 100
    }

    /// Plain-language verdict for an Lc value.
    public static func apcaVerdict(_ lc: Double) -> String {
        switch abs(lc) {
        case 90...: "Any text"
        case 75..<90: "Body text"
        case 60..<75: "Large text only"
        case 45..<60: "Headlines only"
        case 30..<45: "Not for text"
        default: "Invisible"
        }
    }
}
