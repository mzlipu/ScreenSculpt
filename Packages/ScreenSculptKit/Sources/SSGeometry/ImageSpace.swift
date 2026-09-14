// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation

// Image space: origin at the top-left of the captured raster, Y increasing
// downward, measured in device pixels. Annotation geometry, raster operations
// and every measurement live here.

// MARK: - ImagePoint

public struct ImagePoint: Hashable, Codable, Sendable, CustomStringConvertible {
    public var x: ImagePx
    public var y: ImagePx

    public init(x: ImagePx, y: ImagePx) { self.x = x; self.y = y }

    public static let zero = ImagePoint(x: 0, y: 0)

    public var description: String { "(\(x), \(y))" }

    /// Only for handing to CoreGraphics. Never store the result.
    public var cgPoint: CGPoint { CGPoint(x: x.cgFloat, y: y.cgFloat) }
    public init(cgPoint: CGPoint) { self.init(x: ImagePx(cgPoint.x), y: ImagePx(cgPoint.y)) }

    public static func + (p: ImagePoint, v: ImageVector) -> ImagePoint {
        ImagePoint(x: p.x + v.dx, y: p.y + v.dy)
    }
    public static func - (p: ImagePoint, v: ImageVector) -> ImagePoint {
        ImagePoint(x: p.x - v.dx, y: p.y - v.dy)
    }
    /// The displacement from `rhs` to `lhs`.
    public static func - (lhs: ImagePoint, rhs: ImagePoint) -> ImageVector {
        ImageVector(dx: lhs.x - rhs.x, dy: lhs.y - rhs.y)
    }

    public func rounded() -> ImagePoint { ImagePoint(x: x.rounded(), y: y.rounded()) }

    public func distance(to other: ImagePoint) -> ImagePx { (other - self).length }
}

// MARK: - ImageVector

public struct ImageVector: Hashable, Codable, Sendable, CustomStringConvertible {
    public var dx: ImagePx
    public var dy: ImagePx

    public init(dx: ImagePx, dy: ImagePx) { self.dx = dx; self.dy = dy }

    public static let zero = ImageVector(dx: 0, dy: 0)

    public var description: String { "→(\(dx), \(dy))" }

    public var length: ImagePx { ImagePx((dx.value * dx.value + dy.value * dy.value).squareRoot()) }

    public static func + (a: ImageVector, b: ImageVector) -> ImageVector {
        ImageVector(dx: a.dx + b.dx, dy: a.dy + b.dy)
    }
    public static func - (a: ImageVector, b: ImageVector) -> ImageVector {
        ImageVector(dx: a.dx - b.dx, dy: a.dy - b.dy)
    }
    public static prefix func - (v: ImageVector) -> ImageVector {
        ImageVector(dx: -v.dx, dy: -v.dy)
    }
    public static func * (v: ImageVector, s: Double) -> ImageVector {
        ImageVector(dx: v.dx * s, dy: v.dy * s)
    }

    public func rounded() -> ImageVector { ImageVector(dx: dx.rounded(), dy: dy.rounded()) }
}

// MARK: - ImageSize

public struct ImageSize: Hashable, Codable, Sendable, CustomStringConvertible {
    public var width: ImagePx
    public var height: ImagePx

    public init(width: ImagePx, height: ImagePx) { self.width = width; self.height = height }
    /// Pixel dimensions as reported by a `CGImage`.
    public init(pixelWidth: Int, pixelHeight: Int) {
        self.init(width: ImagePx(Double(pixelWidth)), height: ImagePx(Double(pixelHeight)))
    }

    public static let zero = ImageSize(width: 0, height: 0)

    public var description: String { "\(width)×\(height)" }

    public var isEmpty: Bool { width <= .zero || height <= .zero }
    public var area: Double { width.value * height.value }
    public var aspectRatio: Double { height.value == 0 ? 0 : width.value / height.value }

    /// Integer pixel dimensions, for allocating bitmap contexts.
    public var pixelWidth: Int { Int(width.value.rounded()) }
    public var pixelHeight: Int { Int(height.value.rounded()) }

    public var cgSize: CGSize { CGSize(width: width.cgFloat, height: height.cgFloat) }

    public static func * (s: ImageSize, f: Double) -> ImageSize {
        ImageSize(width: s.width * f, height: s.height * f)
    }
}

// MARK: - ImageRect

public struct ImageRect: Hashable, Codable, Sendable, CustomStringConvertible {
    public var origin: ImagePoint
    public var size: ImageSize

    public init(origin: ImagePoint, size: ImageSize) { self.origin = origin; self.size = size }

    public init(x: ImagePx, y: ImagePx, width: ImagePx, height: ImagePx) {
        self.init(origin: ImagePoint(x: x, y: y), size: ImageSize(width: width, height: height))
    }

    /// Normalises so that width and height are non-negative — the shape a
    /// marquee produces when dragged up and to the left.
    public init(corner a: ImagePoint, opposite b: ImagePoint) {
        let minX = ImagePx.min(a.x, b.x), maxX = ImagePx.max(a.x, b.x)
        let minY = ImagePx.min(a.y, b.y), maxY = ImagePx.max(a.y, b.y)
        self.init(
            origin: ImagePoint(x: minX, y: minY),
            size: ImageSize(width: maxX - minX, height: maxY - minY)
        )
    }

    public init(size: ImageSize) { self.init(origin: .zero, size: size) }

    public static let zero = ImageRect(origin: .zero, size: .zero)

    public var description: String { "[\(origin) \(size)]" }

    public var minX: ImagePx { origin.x }
    public var minY: ImagePx { origin.y }
    public var maxX: ImagePx { origin.x + size.width }
    public var maxY: ImagePx { origin.y + size.height }
    public var midX: ImagePx { origin.x + size.width / 2 }
    public var midY: ImagePx { origin.y + size.height / 2 }
    public var width: ImagePx { size.width }
    public var height: ImagePx { size.height }
    public var center: ImagePoint { ImagePoint(x: midX, y: midY) }
    public var isEmpty: Bool { size.isEmpty }

    public var cgRect: CGRect { CGRect(origin: origin.cgPoint, size: size.cgSize) }
    public init(cgRect: CGRect) {
        self.init(
            x: ImagePx(cgRect.origin.x), y: ImagePx(cgRect.origin.y),
            width: ImagePx(cgRect.size.width), height: ImagePx(cgRect.size.height)
        )
    }

    public func contains(_ point: ImagePoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func intersects(_ other: ImageRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }

    public func intersection(_ other: ImageRect) -> ImageRect {
        let x0 = ImagePx.max(minX, other.minX), x1 = ImagePx.min(maxX, other.maxX)
        let y0 = ImagePx.max(minY, other.minY), y1 = ImagePx.min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return .zero }
        return ImageRect(
            origin: ImagePoint(x: x0, y: y0),
            size: ImageSize(width: x1 - x0, height: y1 - y0)
        )
    }

    public func union(_ other: ImageRect) -> ImageRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = ImagePx.min(minX, other.minX), x1 = ImagePx.max(maxX, other.maxX)
        let y0 = ImagePx.min(minY, other.minY), y1 = ImagePx.max(maxY, other.maxY)
        return ImageRect(
            origin: ImagePoint(x: x0, y: y0),
            size: ImageSize(width: x1 - x0, height: y1 - y0)
        )
    }

    /// Positive `by` grows the rect on all four sides.
    public func insetBy(_ by: ImagePx) -> ImageRect {
        ImageRect(
            origin: ImagePoint(x: minX + by, y: minY + by),
            size: ImageSize(width: width - by * 2, height: height - by * 2)
        )
    }
    public func outsetBy(_ by: ImagePx) -> ImageRect { insetBy(-by) }

    public func offsetBy(_ v: ImageVector) -> ImageRect {
        ImageRect(origin: origin + v, size: size)
    }

    /// Snaps to whole pixels, growing outward. Used for invalidation rects so a
    /// half-pixel stroke edge is never clipped.
    public func integralOutward() -> ImageRect {
        let x0 = minX.rounded(.down), y0 = minY.rounded(.down)
        let x1 = maxX.rounded(.up), y1 = maxY.rounded(.up)
        return ImageRect(
            origin: ImagePoint(x: x0, y: y0),
            size: ImageSize(width: x1 - x0, height: y1 - y0)
        )
    }

    public func clamped(to bounds: ImageRect) -> ImageRect { intersection(bounds) }
}

extension Sequence where Element == ImageRect {
    /// Union of every rect in the sequence, or `.zero` when empty.
    public func unioned() -> ImageRect { reduce(ImageRect.zero) { $0.union($1) } }
}
