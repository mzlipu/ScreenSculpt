// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging

/// Joining captures together.
enum Compositor {

    /// Place `addition` below or beside `base`, on one canvas.
    ///
    /// The shorter image is centred on the joining axis and the gap filled,
    /// rather than stretching either to match — a stretched screenshot is no
    /// longer evidence of anything.
    static func append(
        _ addition: RasterImage, to base: RasterImage, at edge: AppendEdge
    ) -> RasterImage? {
        let baseWidth = base.size.pixelWidth, baseHeight = base.size.pixelHeight
        let addWidth = addition.size.pixelWidth, addHeight = addition.size.pixelHeight
        guard baseWidth > 0, baseHeight > 0, addWidth > 0, addHeight > 0 else { return nil }

        let width = edge == .bottom ? max(baseWidth, addWidth) : baseWidth + addWidth
        let height = edge == .bottom ? baseHeight + addHeight : max(baseHeight, addHeight)

        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: base.cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // CoreGraphics counts from the bottom here, so the base goes at the top
        // of the canvas, which is the higher y.
        switch edge {
        case .bottom:
            context.draw(addition.cgImage, in: CGRect(
                x: (width - addWidth) / 2, y: 0, width: addWidth, height: addHeight
            ))
            context.draw(base.cgImage, in: CGRect(
                x: (width - baseWidth) / 2, y: addHeight, width: baseWidth, height: baseHeight
            ))
        case .right:
            context.draw(base.cgImage, in: CGRect(
                x: 0, y: height - baseHeight, width: baseWidth, height: baseHeight
            ))
            context.draw(addition.cgImage, in: CGRect(
                x: baseWidth, y: height - addHeight, width: addWidth, height: addHeight
            ))
        }

        guard let output = context.makeImage() else { return nil }
        return RasterImage(cgImage: output, pixelScale: base.pixelScale)
    }
}
