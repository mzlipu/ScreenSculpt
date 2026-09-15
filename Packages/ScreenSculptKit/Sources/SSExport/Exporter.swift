// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Foundation
import SSGeometry
import SSImaging

public enum SaveFormat: String, Sendable, CaseIterable {
    /// PNG for interfaces, JPEG for photographic content — decided per image.
    case auto
    case png
    case jpeg

    public func resolved(for image: RasterImage) -> ImageFormat {
        switch self {
        case .auto: ImageCodec.automaticFormat(for: image)
        case .png: .png
        case .jpeg: .jpeg
        }
    }
}

public enum ExportError: Error, LocalizedError {
    case noDestinationFolder
    case writeFailed(URL, any Error)

    public var errorDescription: String? {
        switch self {
        case .noDestinationFolder: "No screenshots folder is configured."
        case .writeFailed(let url, let error):
            "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

public struct ExportReceipt: Sendable {
    public let url: URL
    public let format: ImageFormat
    public let byteCount: Int
}

public enum Exporter {

    /// Default destination when the user has not chosen one.
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("Screenshots", isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// `SCR-20260914-072530.png`, with a numeric suffix on collision.
    ///
    /// The timestamp is deliberately ordered largest-unit-first so files sort
    /// chronologically when sorted by name.
    public static func filename(
        for format: ImageFormat, at date: Date = Date(), template: String = "SCR-%Y%m%d-%H%M%S"
    ) -> String {
        var time = time_t(date.timeIntervalSince1970)
        var parts = tm()
        localtime_r(&time, &parts)
        var buffer = [CChar](repeating: 0, count: 128)
        let written = strftime(&buffer, buffer.count, template, &parts)
        let bytes = buffer.prefix(written).map { UInt8(bitPattern: $0) }
        let stem = String(bytes: bytes, encoding: .utf8) ?? "SCR"
        return "\(stem).\(format.fileExtension)"
    }

    private static func uniqueURL(in folder: URL, filename: String) -> URL {
        let candidate = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for suffix in 2...999 {
            let next = folder.appendingPathComponent("\(stem)-\(suffix).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return folder.appendingPathComponent("\(stem)-\(UUID().uuidString).\(ext)")
    }

    // MARK: - Save

    @discardableResult
    public static func save(
        _ image: RasterImage,
        to folder: URL? = nil,
        format: SaveFormat = .auto,
        downscaleToOneX: Bool = false
    ) throws -> ExportReceipt {
        let destination = folder ?? defaultFolder
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true
        )

        let subject = downscaleToOneX ? (image.downscaledTo1x() ?? image) : image
        let resolved = format.resolved(for: subject)
        let data = try ImageCodec.encode(subject, as: resolved)
        let url = uniqueURL(in: destination, filename: filename(for: resolved))

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(url, error)
        }
        return ExportReceipt(url: url, format: resolved, byteCount: data.count)
    }
}
