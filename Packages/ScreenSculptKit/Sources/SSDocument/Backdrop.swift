// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging

/// Presentation applied around a finished screenshot.
///
/// Deliberately **not** a raster operation and **not** an annotation. Padding
/// the image would move its origin, and every annotation is positioned in image
/// pixels — so a backdrop applied partway through editing would silently shift
/// all existing markup. It is instead a property of the document, applied once
/// after annotations are composited, which is also what it is conceptually:
/// a frame around the finished thing rather than a change to it.
public struct Backdrop: Sendable, Equatable, Codable {

    public enum Background: Sendable, Equatable, Codable {
        case solid(RGBA)
        /// Top-to-bottom, the direction almost every such image uses.
        case gradient(from: RGBA, to: RGBA)
    }

    /// A colour that can be stored in a document, without a CoreGraphics type.
    public struct RGBA: Sendable, Equatable, Codable {
        public var r: Double, g: Double, b: Double, a: Double
        public init(r: Double, g: Double, b: Double, a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }
        public var cgColor: CGColor {
            CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    components: [r, g, b, a])!
        }
    }

    /// Space around the screenshot, as a fraction of its shorter side. Relative
    /// rather than absolute so the result looks the same whether the capture
    /// was a small dialog or a whole display.
    public var paddingFraction: Double
    /// Corner rounding on the screenshot itself, in image pixels.
    public var cornerRadius: Double
    public var shadowRadius: Double
    public var shadowOpacity: Double
    public var background: Background

    public init(
        paddingFraction: Double = 0.08,
        cornerRadius: Double = 14,
        shadowRadius: Double = 28,
        shadowOpacity: Double = 0.30,
        background: Background = .gradient(
            from: RGBA(r: 0.42, g: 0.62, b: 0.94),
            to: RGBA(r: 0.24, g: 0.33, b: 0.71)
        )
    ) {
        self.paddingFraction = paddingFraction
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.background = background
    }

    public static let plain = Backdrop(
        paddingFraction: 0.06, cornerRadius: 10, shadowRadius: 18, shadowOpacity: 0.22,
        background: .solid(RGBA(r: 0.94, g: 0.94, b: 0.96))
    )

    public static let dark = Backdrop(
        background: .solid(RGBA(r: 0.11, g: 0.12, b: 0.15))
    )

    /// Padding this backdrop adds to each side of an image of that size.
    ///
    /// Exposed because annotations live in image pixels: adding a backdrop
    /// moves the picture, so everything already marked on it has to move by the
    /// same amount or it ends up pointing at the wrong place.
    public func padding(for size: ImageSize) -> Double {
        let shorter = min(Double(size.pixelWidth), Double(size.pixelHeight))
        return (shorter * max(0, paddingFraction)).rounded()
    }

    /// Wrap an image.
    ///
    /// Takes the already-composited image, so annotations are inside the
    /// rounded corners and under the shadow, which is what makes the result
    /// look like one object rather than a screenshot sitting on a rectangle.
    public func apply(to image: RasterImage) -> RasterImage {
        let width = Double(image.size.pixelWidth)
        let height = Double(image.size.pixelHeight)
        guard width > 0, height > 0 else { return image }

        let padding = padding(for: image.size)
        let canvasWidth = Int(width + padding * 2)
        let canvasHeight = Int(height + padding * 2)

        guard let context = CGContext(
            data: nil, width: canvasWidth, height: canvasHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        drawBackground(in: context, width: canvasWidth, height: canvasHeight)

        let frame = CGRect(x: padding, y: padding, width: width, height: height)
        let path = CGPath(
            roundedRect: frame,
            cornerWidth: CGFloat(cornerRadius), cornerHeight: CGFloat(cornerRadius),
            transform: nil
        )

        if shadowRadius > 0, shadowOpacity > 0 {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -padding * 0.18),
                blur: CGFloat(shadowRadius),
                color: CGColor(gray: 0, alpha: shadowOpacity)
            )
            // The shadow is cast by an opaque shape behind the screenshot. Cast
            // from the image itself it would be drawn *through* any
            // transparency in the capture.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image.cgImage, in: frame)
        context.restoreGState()

        guard let output = context.makeImage() else { return image }
        return RasterImage(cgImage: output, pixelScale: image.pixelScale)
    }

    private func drawBackground(in context: CGContext, width: Int, height: Int) {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        switch background {
        case .solid(let colour):
            context.setFillColor(colour.cgColor)
            context.fill(rect)
        case .gradient(let from, let to):
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [from.cgColor, to.cgColor] as CFArray, locations: [0, 1]
            ) else {
                context.setFillColor(from.cgColor)
                context.fill(rect)
                return
            }
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: rect.maxY),
                end: CGPoint(x: 0, y: 0), options: []
            )
        }
    }
}
