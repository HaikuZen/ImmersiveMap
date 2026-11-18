// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import PortableFoundation
#if canImport(zlib)
import zlib
#endif

/// The gzip step for directories and tiles. zlib rather than the Compression
/// framework because the latter speaks raw deflate only: the gzip member
/// header with its optional name and comment fields, the CRC and the size
/// trailer would all be ours to parse. `inflateInit2` with window bits 15+32
/// reads gzip and zlib wrapping alike and verifies the trailer.
///
/// zlib is a module of Apple's SDKs. A platform without it (Linux as this
/// package builds there, WebAssembly) inflates with `PMTilesInflate`, which
/// reads the same two wrappings and verifies the same trailers.
package enum PMTilesGzip {
    /// A directory or a tile larger than this is a corrupt length, not data.
    package static let maximumOutputByteCount = 64 * 1024 * 1024

    /// Returns `data` unchanged for `.none`, inflates it for `.gzip`. Any
    /// other compression was rejected by the header parser already.
    package static func decompress(_ data: Data, compression: PMTilesCompression) throws -> Data {
        switch compression {
        case .none:
            return data
        case .gzip:
            return try inflate(data)
        case .unknown, .brotli, .zstd:
            throw PMTilesFormatError.unsupportedCompression(compression.rawValue)
        }
    }

    /// `data` as one gzip member, at zlib's best compression: what a writer
    /// puts in an archive for `decompress` to read back. Where there is no
    /// zlib, the member's deflate blocks are stored, not compressed
    /// (`storedGzip`): larger, read alike by every reader.
    package static func deflate(_ data: Data) throws -> Data {
        #if canImport(zlib)
        return try deflateWithZlib(data)
        #else
        return storedGzip(data)
        #endif
    }

    /// One gzip member whose deflate stream is stored blocks of at most
    /// 65535 bytes (RFC 1951, 3.2.4), with gzip's header and its CRC-32 and
    /// size trailer (RFC 1952).
    package static func storedGzip(_ data: Data) -> Data {
        let input = [UInt8](data)
        var output: [UInt8] = [0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0, 0xFF]
        var offset = 0
        repeat {
            let count = min(65535, input.count - offset)
            let isFinal = offset + count == input.count
            output.append(isFinal ? 1 : 0)
            output += [UInt8(count & 0xFF), UInt8(count >> 8), UInt8(~count & 0xFF), UInt8((~count >> 8) & 0xFF)]
            output += input[offset ..< offset + count]
            offset += count
        } while offset < input.count
        let checksum = PMTilesInflate.crc32(input)
        let size = UInt32(truncatingIfNeeded: input.count)
        for value in [checksum, size] {
            output += [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
        }
        return Data(output)
    }

    #if canImport(zlib)
    private static func deflateWithZlib(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, 15 + 16, 9, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw PMTilesWriterError.compressionFailed
        }
        defer { deflateEnd(&stream) }

        var input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(input.count))) + 64)
        var produced = 0
        var finished = false
        input.withUnsafeMutableBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = inputBuffer.baseAddress
                stream.avail_in = UInt32(inputBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = UInt32(outputBuffer.count)
                finished = zlib.deflate(&stream, Z_FINISH) == Z_STREAM_END
                produced = outputBuffer.count - Int(stream.avail_out)
            }
        }
        guard finished else {
            throw PMTilesWriterError.compressionFailed
        }
        return Data(output[0..<produced])
    }
    #endif

    package static func inflate(_ data: Data, expectedByteCount: Int? = nil) throws -> Data {
        guard data.isEmpty == false else {
            return Data()
        }
        #if canImport(zlib)
        return try inflateWithZlib(data, expectedByteCount: expectedByteCount)
        #else
        return try PMTilesInflate.inflate(data,
                                          maximumOutputByteCount: Self.maximumOutputByteCount,
                                          expectedByteCount: expectedByteCount)
        #endif
    }

    #if canImport(zlib)
    private static func inflateWithZlib(_ data: Data, expectedByteCount: Int?) throws -> Data {
        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw PMTilesFormatError.corruptCompressedData
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunkSize = max(16 * 1024, min(Self.maximumOutputByteCount, expectedByteCount ?? data.count * 4))
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        var input = [UInt8](data)

        var status: Int32 = Z_OK
        try input.withUnsafeMutableBufferPointer { inputBuffer in
            stream.next_in = inputBuffer.baseAddress
            stream.avail_in = UInt32(inputBuffer.count)
            repeat {
                try chunk.withUnsafeMutableBufferPointer { chunkBuffer in
                    stream.next_out = chunkBuffer.baseAddress
                    stream.avail_out = UInt32(chunkBuffer.count)
                    status = zlib.inflate(&stream, Z_NO_FLUSH)
                    switch status {
                    case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                        break
                    default:
                        throw PMTilesFormatError.corruptCompressedData
                    }
                    let produced = chunkBuffer.count - Int(stream.avail_out)
                    if produced > 0 {
                        guard output.count + produced <= Self.maximumOutputByteCount else {
                            throw PMTilesFormatError.decompressedDataTooLarge
                        }
                        output.append(chunkBuffer.baseAddress!, count: produced)
                    }
                }
                // Z_BUF_ERROR with no input left and nothing produced is a
                // truncated stream: the trailer never came.
                if status == Z_BUF_ERROR, stream.avail_in == 0 {
                    throw PMTilesFormatError.corruptCompressedData
                }
            } while status != Z_STREAM_END
        }
        return output
    }
    #endif
}
