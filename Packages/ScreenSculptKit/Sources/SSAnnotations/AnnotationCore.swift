// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry

// MARK: - Identity

public struct AnnotationID: Hashable, Codable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

public enum AnnotationKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case arrow, line, rectangle, oval, text, freehand, highlighter, counter, conceal
    case spotlight, magnifier, ruler, imageOverlay

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .text: "Text"
        case .freehand: "Freehand"
        case .highlighter: "Highlighter"
        case .counter: "Counter"
        case .conceal: "Blur"
        case .spotlight: "Spotlight"
        case .magnifier: "Magnifier"
        case .ruler: "Ruler"
        case .imageOverlay: "Image"
        }
    }

    /// SF Symbol for the toolbar.
    public var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .oval: "oval"
        case .text: "textformat"
        case .freehand: "scribble"
        case .highlighter: "highlighter"
        case .counter: "1.circle"
        case .conceal: "drop.fill"
        case .spotlight: "light.beacon.max"
        case .magnifier: "magnifyingglass.circle"
        case .ruler: "ruler"
        case .imageOverlay: "photo"
        }
    }

    /// Tools that can be created by dragging, and so belong on the toolbar.
    ///
    /// An image overlay cannot: its content comes from a file or the clipboard,
    /// so selecting it as a tool and dragging produces an empty frame. It is
    /// placed from the Draw menu instead.
    public static var toolbarTools: [AnnotationKind] {
        allCases.filter { $0 != .imageOverlay }
    }

    /// Whether a bare drag on the canvas can create this.
    public var isDrawable: Bool { self != .imageOverlay }

    public var shortcut: String {
        switch self {
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .oval: "o"
        case .text: "t"
        case .freehand: "d"
        case .highlighter: "h"
        case .counter: "n"
        case .conceal: "b"
        case .spotlight: "s"
        case .magnifier: "m"
        case .ruler: "u"
        case .imageOverlay: "i"
        }
    }
}

// MARK: - Z-order

/// Fractional depth.
///
/// A `Double` rather than an array index so bring-to-front is `maxZ + 1` — O(1),
/// no renumbering, and an undo entry that touches one field instead of every
/// object in the document.
public struct ZIndex: Comparable, Codable, Sendable, Hashable {
    public var value: Double
    public init(_ value: Double) { self.value = value }

    public static func < (lhs: ZIndex, rhs: ZIndex) -> Bool { lhs.value < rhs.value }

    /// Midpoint insertion. After ~50 successive inserts between the same pair
    /// the gap underflows, so ``OrderedAnnotations`` renormalises at save time.
    public static func between(_ a: ZIndex, _ b: ZIndex) -> ZIndex {
        ZIndex((a.value + b.value) / 2)
    }
}

// MARK: - Style

public struct RGBAColor: Hashable, Codable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [r, g, b, a]
        )!
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(r: r, g: g, b: b, a: alpha)
    }

    public static let red = RGBAColor(r: 0.93, g: 0.21, b: 0.20)
    public static let amber = RGBAColor(r: 1.00, g: 0.80, b: 0.10)
    public static let green = RGBAColor(r: 0.20, g: 0.74, b: 0.36)
    public static let blue = RGBAColor(r: 0.15, g: 0.48, b: 0.95)
    public static let magenta = RGBAColor(r: 0.85, g: 0.20, b: 0.70)
    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)

    public static let palette: [RGBAColor] = [red, amber, green, blue, magenta, white, black]
}

public enum StrokeDash: String, Codable, Sendable, CaseIterable {
    case solid, dashed, dotted

    public func pattern(width: Double) -> [CGFloat]? {
        switch self {
        case .solid: nil
        case .dashed: [CGFloat(width * 3), CGFloat(width * 2)]
        case .dotted: [CGFloat(width * 0.1), CGFloat(width * 2)]
        }
    }
}

public enum FillMode: String, Codable, Sendable, CaseIterable {
    case none, translucent, opaque

    public var alpha: Double {
        switch self {
        case .none: 0
        case .translucent: 0.25
        case .opaque: 1
        }
    }
}

public struct AnnotationStyle: Hashable, Codable, Sendable {
    public var color: RGBAColor
    public var strokeWidth: Double      // image pixels
    public var dash: StrokeDash
    public var fill: FillMode
    public var fontSize: Double         // image pixels
    public var opacity: Double

    public init(
        color: RGBAColor = .red,
        strokeWidth: Double = 4,
        dash: StrokeDash = .solid,
        fill: FillMode = .none,
        fontSize: Double = 28,
        opacity: Double = 1
    ) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.dash = dash
        self.fill = fill
        self.fontSize = fontSize
        self.opacity = opacity
    }

    /// Stroke widths scale with the capture, so a 4px line looks the same
    /// weight on a 1× and a 2× screenshot.
    public func scaled(for pixelScale: PixelScale) -> AnnotationStyle {
        var copy = self
        copy.strokeWidth *= pixelScale.value
        copy.fontSize *= pixelScale.value
        return copy
    }
}

// MARK: - Handles

public enum HandleRole: Hashable, Codable, Sendable {
    case corner(Corner)
    case endpoint(Bool)       // true = start
    case bend
    case vertex(Int)

    public enum Corner: String, Codable, Sendable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
}

public struct Handle: Identifiable, Sendable, Equatable {
    public let role: HandleRole
    public let position: ImagePoint

    public var id: HandleRole { role }

    public init(role: HandleRole, position: ImagePoint) {
        self.role = role
        self.position = position
    }
}

/// A handle being dragged, with the delta already converted to image pixels.
public struct HandleEdit: Sendable {
    public let role: HandleRole
    public let location: ImagePoint
    public let constrain: Bool     // Shift held: square / 45°

    public init(role: HandleRole, location: ImagePoint, constrain: Bool) {
        self.role = role
        self.location = location
        self.constrain = constrain
    }
}

public enum HitResult: Sendable, Equatable {
    case handle(HandleRole)
    case body
}

// MARK: - Snapping

public struct SnapCandidate: Sendable, Equatable {
    public enum Axis: Sendable { case horizontal, vertical }
    public let axis: Axis
    public let position: ImagePx
    public let owner: AnnotationID?

    public init(axis: Axis, position: ImagePx, owner: AnnotationID?) {
        self.axis = axis
        self.position = position
        self.owner = owner
    }
}
