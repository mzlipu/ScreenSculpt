// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors
//
// Draws the application icon at every size macOS asks for.
//
// Drawn rather than exported because an icon is needed at 16 points and at
// 1024, and one raster cannot serve both: downscaling a detailed render turns
// to mush at menu bar size, and upscaling a small one is worse. Geometry
// re-evaluated per size stays crisp at each, and the source of truth lives in
// the repository where it can be changed and diffed.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

/// Sampled from the reference artwork so the drawn icon keeps its colours.
let lightBlue = CGColor(red: 0.290, green: 0.749, blue: 0.937, alpha: 1)   // #4ABFEF
let deepBlue = CGColor(red: 0.039, green: 0.373, blue: 0.831, alpha: 1)    // #0A5FD4

// MARK: - Shapes

/// Apple's icon shape is a squircle — a superellipse, not a rounded rectangle.
/// Circular corners read as visibly "pillowed" beside system icons.
func squircle(in rect: CGRect, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

/// One corner bracket of a capture marquee.
func bracket(at corner: CGPoint, arm: Double, weight: Double, dx: Double, dy: Double) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    path.addLine(to: CGPoint(x: corner.x, y: corner.y))
    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    return path.copy(strokingWithWidth: weight, lineCap: .round, lineJoin: .round,
                     miterLimit: 10)
}

/// A camera iris, rendered on its own transparent layer.
///
/// Drawn by erasing rather than by even-odd filling. A real iris is overlapping
/// blades, so its gaps cross one another, and crossing subpaths flip parity —
/// under even-odd the overlaps fill back in and the result reads as a cog. On
/// its own layer the gaps can simply be cleared, and overlaps stop mattering.
func irisImage(diameter: Int, colour: CGColor, blades: Int = 6) -> CGImage {
    let side = Double(diameter)
    let context = CGContext(
        data: nil, width: diameter, height: diameter, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)

    let radius = side / 2
    let centre = CGPoint(x: radius, y: radius)
    context.setFillColor(colour)
    context.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))

    let opening = radius * 0.42
    context.setBlendMode(.clear)

    // The opening the blades leave.
    let hole = CGMutablePath()
    for blade in 0..<blades {
        let angle = Double(blade) / Double(blades) * 2 * .pi - .pi / 2
        let point = CGPoint(
            x: centre.x + cos(angle) * opening, y: centre.y + sin(angle) * opening
        )
        if blade == 0 { hole.move(to: point) } else { hole.addLine(to: point) }
    }
    hole.closeSubpath()
    context.addPath(hole)
    context.fillPath()

    // Blade edges: each gap is tangent to the opening, not radial. That offset
    // is the whole difference between an aperture and a wheel.
    context.setLineWidth(radius * 0.085)
    context.setLineCap(.butt)
    for blade in 0..<blades {
        let angle = Double(blade) / Double(blades) * 2 * .pi - .pi / 2
        let touch = CGPoint(
            x: centre.x + cos(angle) * opening, y: centre.y + sin(angle) * opening
        )
        let along = angle + .pi / 2
        context.move(to: touch)
        context.addLine(to: CGPoint(
            x: touch.x + cos(along) * radius * 1.4, y: touch.y + sin(along) * radius * 1.4
        ))
    }
    context.strokePath()

    return context.makeImage()!
}

// MARK: - Drawing

func render(size: Int, template: Bool) -> CGImage {
    let side = Double(size)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // The menu bar wants a monochrome template on transparency; the app icon
    // wants the tile. Same geometry, different ground.
    let body: CGRect
    if template {
        body = CGRect(x: side * 0.06, y: side * 0.06, width: side * 0.88, height: side * 0.88)
    } else {
        // Apple's grid: the tile occupies about 80% of the canvas, and the
        // remaining margin is where the system's own shadow goes. Baking a
        // shadow in here would double it.
        let inset = side * 0.098
        body = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
        context.addPath(squircle(in: body))
        context.clip()
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [lightBlue, deepBlue] as CFArray, locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: body.minX, y: body.maxY),
            end: CGPoint(x: body.maxX, y: body.minY), options: []
        )
        context.resetClip()
    }

    let ink = template
        ? CGColor(gray: 0, alpha: 1)
        : CGColor(gray: 1, alpha: 1)
    context.setFillColor(ink)

    // Marquee brackets, on a square inside the tile.
    let frame = body.insetBy(dx: body.width * 0.205, dy: body.height * 0.205)
    let arm = frame.width * 0.30
    let weight = body.width * (template ? 0.075 : 0.058)
    let corners: [(CGPoint, Double, Double)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
        (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
        (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (point, dx, dy) in corners {
        context.addPath(bracket(at: point, arm: arm, weight: weight, dx: dx, dy: dy))
    }
    context.fillPath()

    // The iris. Below about 32 points the blades cannot resolve, so it becomes
    // a plain disc rather than a grey smudge.
    let radius = frame.width * 0.30
    let centre = CGPoint(x: body.midX, y: body.midY)
    if size >= 48 {
        let diameter = Int((radius * 2).rounded())
        context.draw(
            irisImage(diameter: diameter, colour: ink),
            in: CGRect(x: centre.x - radius, y: centre.y - radius,
                       width: radius * 2, height: radius * 2)
        )
    } else {
        context.addEllipse(in: CGRect(
            x: centre.x - radius * 0.72, y: centre.y - radius * 0.72,
            width: radius * 1.44, height: radius * 1.44
        ))
        context.fillPath()
    }

    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Output

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    write(render(size: base, template: false),
          to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    write(render(size: base * 2, template: false),
          to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

// Menu bar template, at the three scales AppKit asks for.
for (scale, suffix) in [(1, ""), (2, "@2x"), (3, "@3x")] {
    write(render(size: 18 * scale, template: true),
          to: root.appendingPathComponent("MenuBarIcon\(suffix).png"))
}
print("wrote \(iconset.path) and the menu bar template")
