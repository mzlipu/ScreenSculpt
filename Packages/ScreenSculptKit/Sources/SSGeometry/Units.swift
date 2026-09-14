// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation

// MARK: - GeometricScalar

/// A length in one specific coordinate space.
///
/// The whole point of this protocol is that its conformers are *not*
/// interchangeable. `ImagePx`, `LogicalPt` and `ViewPt` are all a `Double`
/// underneath, but the compiler refuses to mix them:
///
/// ```swift
/// let a: ImagePx = 10
/// let b: LogicalPt = 10
/// let c = a + b        // error: cannot convert LogicalPt to ImagePx
/// let d: ImagePx = b   // error: cannot convert LogicalPt to ImagePx
/// ```
///
/// Crossing between them requires naming a `PixelScale`, which is exactly the
/// decision that gets made silently — and wrongly — when everything is a
/// `CGFloat`.
public protocol GeometricScalar: Hashable, Comparable, AdditiveArithmetic, Codable,
    Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral,
    CustomStringConvertible {
    /// The underlying magnitude. Reach for this only at a framework boundary.
    var value: Double { get set }
    init(_ value: Double)

    /// Short suffix used in `description`, e.g. `"px"`.
    static var unitSuffix: String { get }
}

extension GeometricScalar {
    public init(_ value: Int) { self.init(Double(value)) }
    public init(_ value: CGFloat) { self.init(Double(value)) }

    public init(floatLiteral value: Double) { self.init(value) }
    public init(integerLiteral value: Int) { self.init(Double(value)) }

    public static var zero: Self { Self(0) }

    public var cgFloat: CGFloat { CGFloat(value) }
    public var isFinite: Bool { value.isFinite }

    public var description: String {
        let r = (value * 1000).rounded() / 1000
        let text = r == r.rounded() ? String(Int(r)) : String(r)
        return text + Self.unitSuffix
    }

    // Arithmetic is closed over the unit: you may add two lengths in the same
    // space, or scale one by a dimensionless factor, and nothing else.

    public static func + (lhs: Self, rhs: Self) -> Self { Self(lhs.value + rhs.value) }
    public static func - (lhs: Self, rhs: Self) -> Self { Self(lhs.value - rhs.value) }
    public static prefix func - (operand: Self) -> Self { Self(-operand.value) }
    public static func * (lhs: Self, rhs: Double) -> Self { Self(lhs.value * rhs) }
    public static func * (lhs: Double, rhs: Self) -> Self { Self(lhs * rhs.value) }
    public static func / (lhs: Self, rhs: Double) -> Self { Self(lhs.value / rhs) }

    /// Ratio of two lengths in the same space — dimensionless, so it is a plain
    /// `Double` and may be used as a scale factor.
    public static func / (lhs: Self, rhs: Self) -> Double { lhs.value / rhs.value }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }

    public var magnitude: Self { Self(Swift.abs(value)) }
    public func rounded(_ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Self {
        Self(value.rounded(rule))
    }
    public func clamped(to range: ClosedRange<Self>) -> Self {
        Self(Swift.min(Swift.max(value, range.lowerBound.value), range.upperBound.value))
    }

    public static func min(_ a: Self, _ b: Self) -> Self { a < b ? a : b }
    public static func max(_ a: Self, _ b: Self) -> Self { a > b ? a : b }

    // Encode as a bare number rather than `{"value": n}`, so documents stay
    // readable and round-trip cheaply.
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Double.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - The three length units

/// A length in **device pixels of a captured image**.
///
/// This is the app's internal currency. Annotation geometry, measurements,
/// crops and every raster operation are expressed in it, because it is the only
/// unit that does not change meaning when the editor window is dragged to a
/// display with a different backing scale factor.
public struct ImagePx: GeometricScalar {
    public var value: Double
    public init(_ value: Double) { self.value = value }
    public static let unitSuffix = "px"
}

/// A length in **logical points of screen space** — what AppKit and
/// CoreGraphics call a point, and what a designer means by "24pt".
public struct LogicalPt: GeometricScalar {
    public var value: Double
    public init(_ value: Double) { self.value = value }
    public static let unitSuffix = "pt"
}

/// A length in **view points of the editor canvas**, i.e. after the zoom
/// transform. Used for hit tolerances, handle radii and snap thresholds, so
/// that those feel identical at 25% and at 3200%.
public struct ViewPt: GeometricScalar {
    public var value: Double
    public init(_ value: Double) { self.value = value }
    public static let unitSuffix = "vp"
}

// MARK: - PixelScale

/// The ratio of device pixels to logical points for a particular capture.
///
/// Always obtained from `SCContentFilter.pointPixelScale` at capture time and
/// frozen into the document's provenance. Never re-derived from the current
/// `NSScreen`: the user will drag the editor onto a 1× display, and the image's
/// own pixel scale does not change when they do.
public struct PixelScale: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: Double

    public init(_ value: Double) {
        precondition(value > 0, "PixelScale must be positive, got \(value)")
        self.value = value
    }

    /// From `SCContentFilter.pointPixelScale`, which is the authoritative
    /// scale for a capture. Labelled so it cannot collide with the Double init.
    public init(pointPixelScale: Float) { self.init(Double(pointPixelScale)) }

    public static let x1 = PixelScale(1)
    public static let x2 = PixelScale(2)
    public static let x3 = PixelScale(3)

    public var isRetina: Bool { value > 1 }
    public var description: String { "\(value)×" }

    /// Quantises to a power of two, for keying render caches so that expensive
    /// bodies re-rasterise a handful of times across the whole zoom range
    /// rather than on every zoom tick.
    public func bucketed(zoom: Double) -> Int {
        let effective = Swift.max(value * zoom, 0.0001)
        return Int(Foundation.log2(effective).rounded())
    }
}

// MARK: - Crossing between units
//
// These are the *only* conversions between the three length units. Each one
// names a PixelScale explicitly, which is the whole point: a unit change is
// always a visible, deliberate line of code.

extension PixelScale {
    public func pixels(_ points: LogicalPt) -> ImagePx { ImagePx(points.value * value) }
    public func points(_ pixels: ImagePx) -> LogicalPt { LogicalPt(pixels.value / value) }
}

extension ImagePx {
    /// Convert to logical points. On a 2× capture, 64px is 32pt.
    public func inPoints(_ scale: PixelScale) -> LogicalPt { scale.points(self) }
}

extension LogicalPt {
    /// Convert to device pixels. On a 2× capture, 32pt is 64px.
    public func inPixels(_ scale: PixelScale) -> ImagePx { scale.pixels(self) }
}
