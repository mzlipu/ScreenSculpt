// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 The ScreenSculpt Authors

import Compression
import Foundation

public enum PNGEncodingError: Error, LocalizedError {
    case invalidSize
    case compressionFailed
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSize: "The image has no pixels to write."
        case .compressionFailed: "The image could not be compressed."
        case .writeFailed(let detail): "Could not write the file: \(detail)"
        }
    }
}

/// Writes a PNG one scanline at a time.
///
/// `CGImageDestination` takes a whole `CGImage`, and a 200,000-row stitch cannot
/// be one — so the format is written by hand here. Memory stays flat regardless
/// of height: two scanlines, a compression window, and a chunk buffer.
///
/// Layout is RGBA8, non-interlaced, one zlib stream split across IDAT chunks.
public enum StreamingPNGEncoder {

    /// Bytes of compressed output buffered before an IDAT chunk is emitted.
    private static let chunkSize = 64 * 1024

    /// - Parameter row: called once per scanline, in order, and must yield
    ///   exactly `width * 4` bytes of premultiplied RGBA.
    public static func encode(
        width: Int,
        height: Int,
        to url: URL,
        row: (Int, (UnsafeRawBufferPointer) -> Void) throws -> Void
    ) throws {
        guard width > 0, height > 0 else { throw PNGEncodingError.invalidSize }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw PNGEncodingError.writeFailed(url.lastPathComponent)
        }
        defer { try? handle.close() }

        try handle.write(contentsOf: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        var header = Data()
        header.appendBigEndian(UInt32(width))
        header.appendBigEndian(UInt32(height))
        header.append(contentsOf: [8, 6, 0, 0, 0])  // 8-bit, RGBA, no interlace
        try writeChunk(type: "IHDR", payload: header, to: handle)

        try writeImageData(width: width, height: height, to: handle, row: row)
        try writeChunk(type: "IEND", payload: Data(), to: handle)
    }

    // MARK: - Pixel data

    /// Copy one caller-supplied scanline into `current`, zero-filling a short
    /// or missing row so the stream stays the length the header promised.
    private static func collect(
        row index: Int,
        into current: inout [UInt8],
        stride: Int,
        row: (Int, (UnsafeRawBufferPointer) -> Void) throws -> Void
    ) rethrows {
        var received = false
        try row(index) { bytes in
            let count = min(bytes.count, stride)
            current.withUnsafeMutableBytes { target in
                target.copyBytes(from: UnsafeRawBufferPointer(rebasing: bytes[0..<count]))
                if count < stride {
                    memset(target.baseAddress!.advanced(by: count), 0, stride - count)
                }
            }
            received = true
        }
        if !received { for index in 0..<stride { current[index] = 0 } }
    }

    private static func writeImageData(
        width: Int,
        height: Int,
        to handle: FileHandle,
        row: (Int, (UnsafeRawBufferPointer) -> Void) throws -> Void
    ) throws {
        let stride = width * 4
        var previous = [UInt8](repeating: 0, count: stride)
        var current = [UInt8](repeating: 0, count: stride)
        // One filter byte, then the scanline.
        var filtered = [UInt8](repeating: 0, count: stride + 1)

        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
        )
        guard compression_stream_init(
            &stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB
        ) == COMPRESSION_STATUS_OK else { throw PNGEncodingError.compressionFailed }
        defer { compression_stream_destroy(&stream) }

        var output = [UInt8](repeating: 0, count: chunkSize)
        var pending = Data()
        // libcompression's COMPRESSION_ZLIB is raw DEFLATE (RFC 1951); PNG wants
        // a zlib wrapper (RFC 1950), so the 2-byte header and the trailing
        // Adler-32 of the *uncompressed* data are added here.
        pending.append(contentsOf: [0x78, 0x01])
        var adler = Adler32()

        try output.withUnsafeMutableBufferPointer { destination in
            stream.dst_ptr = destination.baseAddress!
            stream.dst_size = destination.count

            func drain(flags: Int32) throws -> Bool {
                let status = compression_stream_process(&stream, flags)
                guard status != COMPRESSION_STATUS_ERROR else {
                    throw PNGEncodingError.compressionFailed
                }
                let produced = destination.count - stream.dst_size
                if produced > 0 {
                    pending.append(destination.baseAddress!, count: produced)
                    stream.dst_ptr = destination.baseAddress!
                    stream.dst_size = destination.count
                    if pending.count >= chunkSize {
                        try writeChunk(type: "IDAT", payload: pending, to: handle)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                return status == COMPRESSION_STATUS_END
            }

            for index in 0..<height {
                try collect(row: index, into: &current, stride: stride, row: row)
                applyFilter(current, previous: previous, into: &filtered)
                adler.update(filtered)

                try filtered.withUnsafeBufferPointer { source in
                    stream.src_ptr = source.baseAddress!
                    stream.src_size = source.count
                    while stream.src_size > 0 {
                        _ = try drain(flags: 0)
                    }
                }
                swap(&previous, &current)
            }

            stream.src_size = 0
            while try !drain(flags: Int32(COMPRESSION_STREAM_FINALIZE.rawValue)) {}
        }

        pending.appendBigEndian(adler.value)
        if !pending.isEmpty {
            try writeChunk(type: "IDAT", payload: pending, to: handle)
        }
    }

    /// Choose between None and Up for each scanline.
    ///
    /// Up is the one that matters for screen content: consecutive rows of a
    /// toolbar, a table or a flat background are near-identical, so the
    /// difference against the row above is mostly zeros. Picking per row by
    /// smallest absolute sum is the heuristic the PNG specification suggests,
    /// and it costs one pass over bytes already in cache.
    private static func applyFilter(
        _ current: [UInt8], previous: [UInt8], into filtered: inout [UInt8]
    ) {
        current.withUnsafeBufferPointer { source in
            previous.withUnsafeBufferPointer { above in
                filtered.withUnsafeMutableBufferPointer { output in
                    let count = source.count
                    var noneScore = 0
                    var upScore = 0
                    for index in 0..<count {
                        noneScore &+= Int(source[index])
                        let delta = source[index] &- above[index]
                        upScore &+= Int(delta < 128 ? delta : 0 &- delta)
                    }

                    if upScore < noneScore {
                        output[0] = 2
                        for index in 0..<count {
                            output[index + 1] = source[index] &- above[index]
                        }
                    } else {
                        output[0] = 0
                        for index in 0..<count { output[index + 1] = source[index] }
                    }
                }
            }
        }
    }

    // MARK: - Chunks

    private static func writeChunk(
        type: String, payload: Data, to handle: FileHandle
    ) throws {
        var chunk = Data()
        chunk.appendBigEndian(UInt32(payload.count))
        let typeBytes = Data(type.utf8)
        chunk.append(typeBytes)
        chunk.append(payload)
        chunk.appendBigEndian(CRC32.checksum(typeBytes + payload))
        try handle.write(contentsOf: chunk)
    }
}

// MARK: - Checksums

struct Adler32 {
    private var a: UInt32 = 1
    private var b: UInt32 = 0

    /// Largest run that cannot overflow `b` before the modulo is applied.
    /// Taking the remainder once per block instead of once per byte is what
    /// makes this affordable over a gigabyte of scanlines.
    private static let blockSize = 5552

    var value: UInt32 { (b << 16) | a }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                let end = min(index + Self.blockSize, buffer.count)
                var localA = a
                var localB = b
                for position in index..<end {
                    localA &+= UInt32(buffer[position])
                    localB &+= localA
                }
                a = localA % 65_521
                b = localB % 65_521
                index = end
            }
        }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { lookup in
            data.withUnsafeBytes { bytes in
                for byte in bytes {
                    crc = lookup[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
}
