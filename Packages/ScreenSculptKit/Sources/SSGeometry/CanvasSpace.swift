// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation

// Canvas space: origin at the top-left of the editor's canvas view, Y down,
// measured in view points. This is what AppKit hands you in a mouse event and
// what chrome (handles, marquee, guides) is drawn in.

// MARK: - CanvasPoint / CanvasSize / CanvasRect

public struct CanvasPoint: Hashable, Sendable, CustomStringConvertible {
    public var x: ViewPt
    public var y: ViewPt

    public init(x: ViewPt, y: ViewPt) { self.x = x; self.y = y }

    public static let zero = CanvasPoint(x: 0, y: 0)
    public var description: String { "(\(x), \(y))" }

    public var cgPoint: CGPoint { CGPoint(x: x.cgFloat, y: y.cgFloat) }
    public init(cgPoint: CGPoint) { self.init(x: ViewPt(cgPoint.x), y: ViewPt(cgPoint.y)) }
}

public struct CanvasSize: Hashable, Sendable, CustomStringConvertible {
    public var width: ViewPt
    public var height: ViewPt

    public init(width: ViewPt, height: ViewPt) { self.width = width; self.height = height }

    public static let zero = CanvasSize(width: 0, height: 0)
    public var description: String { "\(width)×\(height)" }
    public var isEmpty: Bool { width <= .zero || height <= .zero }
    public var cgSize: CGSize { CGSize(width: width.cgFloat, height: height.cgFloat) }
}

public struct CanvasRect: Hashable, Sendable, CustomStringConvertible {
    public var origin: CanvasPoint
    public var size: CanvasSize

    public init(origin: CanvasPoint, size: CanvasSize) { self.origin = origin; self.size = size }
    public init(x: ViewPt, y: ViewPt, width: ViewPt, height: ViewPt) {
        self.init(origin: CanvasPoint(x: x, y: y), size: CanvasSize(width: width, height: height))
    }

    public static let zero = CanvasRect(origin: .zero, size: .zero)
    public var description: String { "[\(origin) \(size)]" }

    public var minX: ViewPt { origin.x }
    public var minY: ViewPt { origin.y }
    public var maxX: ViewPt { origin.x + size.width }
    public var maxY: ViewPt { origin.y + size.height }
    public var width: ViewPt { size.width }
    public var height: ViewPt { size.height }
    public var isEmpty: Bool { size.isEmpty }

    public var cgRect: CGRect { CGRect(origin: origin.cgPoint, size: size.cgSize) }
    public init(cgRect: CGRect) {
        self.init(
            x: ViewPt(cgRect.origin.x), y: ViewPt(cgRect.origin.y),
            width: ViewPt(cgRect.size.width), height: ViewPt(cgRect.size.height)
        )
    }

    public func contains(_ p: CanvasPoint) -> Bool {
        p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY
    }

    public func insetBy(_ by: ViewPt) -> CanvasRect {
        CanvasRect(
            origin: CanvasPoint(x: minX + by, y: minY + by),
            size: CanvasSize(width: width - by * 2, height: height - by * 2)
        )
    }
    public func outsetBy(_ by: ViewPt) -> CanvasRect { insetBy(-by) }
}

// MARK: - CanvasTransform

/// The single conversion authority between image pixels and view points.
///
/// `zoom` is defined as **image pixels per device pixel**, so `zoom == 1`
/// means one pixel of the captured image is painted on exactly one pixel of the
/// display. That is the only definition of "100%" a pixel tool can defend, and
/// it is why `backingScale` appears in every conversion: a view point is
/// `backingScale` device pixels.
///
/// Note this is deliberately *not* `NSScrollView.magnification`, which works by
/// scaling the document view's bounds — that breaks integral pixel snapping and
/// makes `NSView.convert(_:to:)` results depend on the zoom level.
public struct CanvasTransform: Equatable, Sendable {

    /// Image pixels per device pixel. Clamped to ``zoomRange``.
    public let zoom: Double

    /// The image pixel sitting at the canvas view's top-left corner.
    public let imageOrigin: ImagePoint

    /// Device pixels per view point for the display currently showing the
    /// canvas. Refreshed on `NSWindow.didChangeBackingPropertiesNotification`.
    public let backingScale: PixelScale

    public static let zoomRange: ClosedRange<Double> = 0.05...32.0

    /// Keyboard zoom steps. Integer factors at and above 1× are what make
    /// nearest-neighbour magnification produce evenly sized square pixels
    /// instead of an uneven shimmering grid.
    public static let zoomStops: [Double] = [
        0.05, 0.0625, 0.125, 0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0,
        1, 2, 3, 4, 6, 8, 12, 16, 24, 32,
    ]

    public init(zoom: Double, imageOrigin: ImagePoint, backingScale: PixelScale) {
        self.zoom = Swift.min(Swift.max(zoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        self.imageOrigin = imageOrigin
        self.backingScale = backingScale
    }

    public static func identity(backingScale: PixelScale = .x2) -> CanvasTransform {
        CanvasTransform(zoom: 1, imageOrigin: .zero, backingScale: backingScale)
    }

    /// View points per image pixel.
    private var k: Double { zoom / backingScale.value }

    // MARK: Lengths

    public func toCanvas(_ length: ImagePx) -> ViewPt { ViewPt(length.value * k) }
    public func toImage(_ length: ViewPt) -> ImagePx { ImagePx(length.value / k) }

    // MARK: Points

    public func toCanvas(_ p: ImagePoint) -> CanvasPoint {
        CanvasPoint(
            x: ViewPt((p.x.value - imageOrigin.x.value) * k),
            y: ViewPt((p.y.value - imageOrigin.y.value) * k)
        )
    }

    public func toImage(_ p: CanvasPoint) -> ImagePoint {
        ImagePoint(
            x: ImagePx(p.x.value / k + imageOrigin.x.value),
            y: ImagePx(p.y.value / k + imageOrigin.y.value)
        )
    }

    // MARK: Rects

    public func toCanvas(_ r: ImageRect) -> CanvasRect {
        CanvasRect(origin: toCanvas(r.origin), size: CanvasSize(
            width: toCanvas(r.width), height: toCanvas(r.height)
        ))
    }

    public func toImage(_ r: CanvasRect) -> ImageRect {
        ImageRect(origin: toImage(r.origin), size: ImageSize(
            width: toImage(r.width), height: toImage(r.height)
        ))
    }

    /// CTM mapping image space to canvas space. Concatenate this once at the
    /// top of `draw(_:)`; every annotation body then draws in image pixels and
    /// knows nothing about zoom or backing scale.
    public var cgAffine: CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(k), b: 0, c: 0, d: CGFloat(k),
            tx: CGFloat(-imageOrigin.x.value * k),
            ty: CGFloat(-imageOrigin.y.value * k)
        )
    }

    // MARK: Rendering policy

    /// At and above 1:1, magnify with nearest-neighbour. Smoothing above 100%
    /// in a pixel tool is a lie about what is on screen.
    public var usesNearestNeighbour: Bool { zoom >= 1.0 }

    /// Opacity of the per-pixel grid overlay, ramped in between 16× and 24× so
    /// it fades up rather than popping.
    public var pixelGridAlpha: Double {
        guard zoom > 16 else { return 0 }
        return Swift.min((zoom - 16) / 8, 1) * 0.35
    }

    // MARK: Derivation

    public func with(zoom newZoom: Double) -> CanvasTransform {
        CanvasTransform(zoom: newZoom, imageOrigin: imageOrigin, backingScale: backingScale)
    }

    public func with(imageOrigin newOrigin: ImagePoint) -> CanvasTransform {
        CanvasTransform(zoom: zoom, imageOrigin: newOrigin, backingScale: backingScale)
    }

    public func with(backingScale newScale: PixelScale) -> CanvasTransform {
        CanvasTransform(zoom: zoom, imageOrigin: imageOrigin, backingScale: newScale)
    }

    /// Zoom about a fixed point, so the image pixel under the cursor stays put.
    public func zoomed(to newZoom: Double, anchoredAt anchor: CanvasPoint) -> CanvasTransform {
        let anchorImage = toImage(anchor)
        let next = with(zoom: newZoom)
        let anchorAfter = next.toImage(anchor)
        return next.with(imageOrigin: ImagePoint(
            x: next.imageOrigin.x + (anchorImage.x - anchorAfter.x),
            y: next.imageOrigin.y + (anchorImage.y - anchorAfter.y)
        ))
    }

    public func nextZoomStop(increasing: Bool) -> Double {
        if increasing {
            return Self.zoomStops.first { $0 > zoom * 1.0001 } ?? Self.zoomRange.upperBound
        } else {
            return Self.zoomStops.last { $0 < zoom * 0.9999 } ?? Self.zoomRange.lowerBound
        }
    }

    /// Snap the pan offset to whole device pixels.
    ///
    /// Without this, a half-pixel translation makes nearest-neighbour
    /// magnification render an uneven, shimmering grid of pixel blocks at high
    /// zoom — a two-line fix that a lot of editors miss.
    public func snappedToDevicePixels() -> CanvasTransform {
        guard k > 0 else { return self }
        let devicePerImage = zoom
        let snap = { (v: Double) in (v * devicePerImage).rounded() / devicePerImage }
        return with(imageOrigin: ImagePoint(
            x: ImagePx(snap(imageOrigin.x.value)),
            y: ImagePx(snap(imageOrigin.y.value))
        ))
    }

    /// The zoom at which `image` exactly fits `viewport`, capped at 1:1 so a
    /// small capture is never blown up on open.
    public static func fitZoom(
        image: ImageSize, viewport: CanvasSize, backingScale: PixelScale, padding: ViewPt = 24
    ) -> Double {
        guard !image.isEmpty, !viewport.isEmpty else { return 1 }
        let availableW = Swift.max(viewport.width.value - padding.value * 2, 1)
        let availableH = Swift.max(viewport.height.value - padding.value * 2, 1)
        let kFit = Swift.min(availableW / image.width.value, availableH / image.height.value)
        return Swift.min(kFit * backingScale.value, 1.0)
    }
}
