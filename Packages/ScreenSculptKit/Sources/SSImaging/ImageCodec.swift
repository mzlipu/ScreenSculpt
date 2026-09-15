// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import CoreGraphics
import Foundation
import ImageIO
import SSGeometry
import UniformTypeIdentifiers

public enum ImageFormat: String, Sendable, CaseIterable {
    case png
    case jpeg

    public var utType: UTType { self == .png ? .png : .jpeg }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
}

public enum ImageCodecError: Error, LocalizedError {
    case destinationUnavailable
    case encodeFailed
    case decodeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .destinationUnavailable: "Could not create an image destination."
        case .encodeFailed: "Could not encode the image."
        case .decodeFailed(let url): "Could not read an image from \(url.lastPathComponent)."
        }
    }
}

public enum ImageCodec {

    /// JPEG's SOF header stores dimensions in 16 bits, so neither side can
    /// exceed this. A tall scrolling capture must be PNG.
    public static let jpegMaxDimension = 65_535

    // MARK: - Encoding

    public static func encode(
        _ image: RasterImage, as format: ImageFormat, quality: Double = 0.9
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil
        ) else {
            throw ImageCodecError.destinationUnavailable
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        // Tag Retina captures at 144dpi so other applications lay them out at
        // the size the content actually occupied on screen.
        if image.pixelScale.isRetina {
            let dpi = 72.0 * image.pixelScale.value
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }

        CGImageDestinationAddImage(destination, image.cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageCodecError.encodeFailed
        }
        return data as Data
    }

    // MARK: - Decoding

    public static func decode(
        contentsOf url: URL, pixelScale: PixelScale = .x1
    ) throws -> RasterImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageCodecError.decodeFailed(url)
        }
        return RasterImage(cgImage: image, pixelScale: pixelScale)
    }

    // MARK: - Format selection

    /// Choose PNG or JPEG based on what the image actually contains.
    ///
    /// Screenshots of interfaces are mostly flat colour with hard edges, where
    /// PNG is both smaller and lossless. Screenshots containing photographs or
    /// gradients are the opposite. Sampling a grid of pixels and counting
    /// distinct colours separates the two cheaply and reliably enough.
    public static func automaticFormat(for image: RasterImage) -> ImageFormat {
        if max(image.cgImage.width, image.cgImage.height) > jpegMaxDimension {
            return .png
        }

        let side = 64
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .png }

        context.interpolationQuality = .none
        context.draw(image.cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return .png }

        let pixels = data.bindMemory(to: UInt32.self, capacity: side * side)
        var distinct = Set<UInt32>()
        distinct.reserveCapacity(side * side)
        for i in 0..<(side * side) {
            distinct.insert(pixels[i])
            // Plenty of variation already: this is photographic.
            if distinct.count > 1_800 { return .jpeg }
        }
        return .png
    }
}
