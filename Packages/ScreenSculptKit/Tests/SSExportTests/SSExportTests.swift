// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import SSGeometry
import SSImaging
import Testing

@testable import SSExport

private func makeImage(width: Int = 40, height: Int = 30) -> RasterImage {
    let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return RasterImage(cgImage: context.makeImage()!, pixelScale: .x2)
}

@Suite("Filename template")
struct FilenameTests {

    @Test("Timestamps are largest-unit-first so files sort chronologically by name")
    func chronologicalOrdering() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 14
        components.hour = 7; components.minute = 25; components.second = 30
        let earlier = Calendar.current.date(from: components)!
        let later = earlier.addingTimeInterval(3600)

        let first = Exporter.filename(for: .png, at: earlier)
        let second = Exporter.filename(for: .png, at: later)

        // Sorting by name must equal sorting by time — that is the whole point
        // of the format.
        #expect(first < second)
        #expect(first.hasPrefix("SCR-20260914-"))
        #expect(first.hasSuffix(".png"))
    }

    @Test("The extension follows the resolved format")
    func extensionMatchesFormat() {
        let date = Date(timeIntervalSince1970: 1_789_000_000)
        #expect(Exporter.filename(for: .png, at: date).hasSuffix(".png"))
        #expect(Exporter.filename(for: .jpeg, at: date).hasSuffix(".jpg"))
    }

    @Test("A custom template is honoured")
    func customTemplate() {
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 5
        let date = Calendar.current.date(from: components)!
        let name = Exporter.filename(for: .png, at: date, template: "shot-%Y-%m-%d")
        #expect(name == "shot-2026-01-05.png")
    }
}

@Suite("Saving")
struct SaveTests {

    private func scratchFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ss-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Saving writes a real file and reports where")
    func writesFile() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let receipt = try Exporter.save(makeImage(), to: folder, format: .png)
        #expect(FileManager.default.fileExists(atPath: receipt.url.path))
        #expect(receipt.format == .png)
        #expect(receipt.byteCount > 0)

        let onDisk = try Data(contentsOf: receipt.url).count
        #expect(onDisk == receipt.byteCount)
    }

    @Test("The destination folder is created if it does not exist")
    func createsFolder() throws {
        let folder = scratchFolder().appendingPathComponent("nested/deeper", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let receipt = try Exporter.save(makeImage(), to: folder, format: .png)
        #expect(FileManager.default.fileExists(atPath: receipt.url.path))
    }

    @Test("Two saves in the same second do not overwrite each other")
    func collisionsGetASuffix() throws {
        // The filename has one-second resolution, so rapid captures collide.
        // Losing the first one would be silent data loss.
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try Exporter.save(makeImage(), to: folder, format: .png)
        let second = try Exporter.save(makeImage(), to: folder, format: .png)

        #expect(first.url != second.url)
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(FileManager.default.fileExists(atPath: second.url.path))
        #expect(second.url.lastPathComponent.contains("-2"))
    }

    @Test("Downscaling on save halves a 2x capture")
    func downscaleOnSave() throws {
        let folder = scratchFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let receipt = try Exporter.save(
            makeImage(width: 200, height: 100), to: folder, format: .png, downscaleToOneX: true
        )
        let decoded = try ImageCodec.decode(contentsOf: receipt.url)
        #expect(decoded.size == ImageSize(width: 100, height: 50))
    }

    @Test("Auto format resolves per image")
    func autoFormatResolves() {
        #expect(SaveFormat.png.resolved(for: makeImage()) == .png)
        #expect(SaveFormat.jpeg.resolved(for: makeImage()) == .jpeg)
        // Flat synthetic colour is interface-like.
        #expect(SaveFormat.auto.resolved(for: makeImage()) == .png)
    }
}
