// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import ImageIO
import SSAnnotations
import SSDocument
import SSGeometry
import SSImaging
import Testing
import UniformTypeIdentifiers

@testable import SSRender

/// Writes a rendering of the newer tools for a human to look at.
///
/// Disabled by default: it asserts almost nothing, and what it is for is the
/// thing automated tests cannot do — telling whether a spotlight looks like a
/// spotlight. Enable it, run it, and open the file.
@Suite("Visual preview", .disabled("writes a file for inspection; enable to use"))
@MainActor
struct VisualPreview {

    @Test("Render the new tools to /tmp/tools.png")
    func render() throws {
        let w = 640, h = 420
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var seed: UInt64 = 99
        func rnd(_ n: Int) -> Int {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Int(seed % UInt64(n))
        }
        for row in 0..<26 {
            let y = 14 + row * 15
            var x = 20
            while x < 600 {
                let run = 18 + rnd(70)
                ctx.setFillColor(CGColor(gray: Double(30 + rnd(90)) / 255.0, alpha: 1))
                ctx.fill(CGRect(x: x, y: y, width: min(run, 600 - x), height: 7))
                x += run + 8 + rnd(14)
            }
        }
        let base = RasterImage(cgImage: ctx.makeImage()!, pixelScale: .x1)

        let store = DocumentStore(image: base)
        var style = AnnotationStyle()
        style.color = .amber
        style.strokeWidth = 3
        style.fontSize = 20

        store.add(.spotlight(SpotlightBody(
            rect: ImageRect(x: 40, y: 40, width: 250, height: 130), shape: .ellipse)), style: style)
        store.add(.magnifier(MagnifierBody(
            rect: ImageRect(x: 360, y: 50, width: 150, height: 150), zoom: 3)), style: style)
        store.add(.ruler(RulerBody(
            start: ImagePoint(x: ImagePx(60), y: ImagePx(330)),
            end: ImagePoint(x: ImagePx(330), y: ImagePx(330)))), style: style)

        let logo = CGContext(
            data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        logo.setFillColor(CGColor(red: 0.04, green: 0.37, blue: 0.83, alpha: 1))
        logo.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        logo.setFillColor(CGColor(gray: 1, alpha: 1))
        logo.fill(CGRect(x: 14, y: 22, width: 92, height: 16))
        store.add(.imageOverlay(ImageOverlayBody.make(
            from: logo.makeImage()!,
            at: ImageRect(x: 400, y: 280, width: 180, height: 90))!), style: style)

        let out = AnnotationRenderer.flatten(store.document)
        let url = URL(fileURLWithPath: "/tmp/tools.png")
        let dst = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, out.cgImage, nil)
        #expect(CGImageDestinationFinalize(dst))
    }
}
