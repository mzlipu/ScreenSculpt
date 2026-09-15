// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSImaging

public enum ColorFormat: String, Sendable, CaseIterable, Identifiable {
    case hex
    case hexPlain
    case rgb
    case rgba
    case hsl
    case oklch
    case swiftUI

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .hex: "HEX"
        case .hexPlain: "HEX without #"
        case .rgb: "RGB"
        case .rgba: "RGBA"
        case .hsl: "HSL"
        case .oklch: "OKLCH"
        case .swiftUI: "SwiftUI Color"
        }
    }
}

public enum ColorFormatter {

    /// Format for display and for the clipboard — the same string, so what the
    /// readout shows is exactly what gets pasted.
    public static func string(for color: RGBA8, as format: ColorFormat) -> String {
        let r = Double(color.r) / 255, g = Double(color.g) / 255, b = Double(color.b) / 255

        switch format {
        case .hex:
            return String(format: "#%02X%02X%02X", color.r, color.g, color.b)
        case .hexPlain:
            return String(format: "%02X%02X%02X", color.r, color.g, color.b)
        case .rgb:
            return "rgb(\(color.r), \(color.g), \(color.b))"
        case .rgba:
            let alpha = (Double(color.a) / 255 * 100).rounded() / 100
            return "rgba(\(color.r), \(color.g), \(color.b), \(trim(alpha)))"
        case .hsl:
            let hsl = ColorSpaces.hsl(r: r, g: g, b: b)
            return "hsl(\(Int(hsl.h.rounded())), "
                + "\(Int((hsl.s * 100).rounded()))%, "
                + "\(Int((hsl.l * 100).rounded()))%)"
        case .oklch:
            let lch = ColorSpaces.oklch(r: r, g: g, b: b)
            return "oklch(\(percent(lch.l)) \(trim(round(lch.c, places: 4))) "
                + "\(trim(round(lch.h, places: 1))))"
        case .swiftUI:
            return "Color(red: \(trim(round(r, places: 3))), "
                + "green: \(trim(round(g, places: 3))), "
                + "blue: \(trim(round(b, places: 3))))"
        }
    }

    private static func round(_ value: Double, places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (value * factor).rounded() / factor
    }

    private static func percent(_ value: Double) -> String {
        "\(trim(round(value * 100, places: 1)))%"
    }

    /// Drop a trailing `.0`, so values read as `12` rather than `12.0`.
    private static func trim(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
