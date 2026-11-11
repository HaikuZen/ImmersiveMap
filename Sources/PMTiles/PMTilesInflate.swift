// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

/// Inflate in Swift, for the platforms that have no zlib to call
/// (WebAssembly first). It reads what `PMTilesGzip` asks zlib for: one gzip
/// member or one zlib stream, the header parsed and the checksum of the
/// trailer verified, and whatever follows the member left alone.
///
/// The decoder is the plain one, a bit at a time through canonical Huffman
/// codes, after Mark Adler's `puff`. It is several times slower than zlib,
/// which is why Apple's platforms keep zlib, and it is enough for tiles of a
/// few hundred kilobytes. A platform that reads large archives with it would
/// want table lookups in `HuffmanCode.decode`.
package enum PMTilesInflate {
    /// Inflates one gzip member or zlib stream. Throws
    /// `PMTilesFormatError.corruptCompressedData` for anything that is not
    /// one, a truncated one included, and `.decompressedDataTooLarge` when
    /// the output would pass `maximumOutputByteCount`.
    package static func inflate(_ data: Data,
                                maximumOutputByteCount: Int,
                                expectedByteCount: Int? = nil) throws -> Data {
        let input = [UInt8](data)
        let output = try input.withUnsafeBufferPointer { bytes -> [UInt8] in
            var reader = BitReader(bytes: bytes)
            let wrapping = try readHeader(&reader)
            var output: [UInt8] = []
            output.reserveCapacity(min(maximumOutputByteCount, expectedByteCount ?? bytes.count * 4))
            try inflateBlocks(&reader, into: &output, maximumOutputByteCount: maximumOutputByteCount)
            try verifyTrailer(&reader, wrapping: wrapping, output: output)
            return output
        }
        return Data(output)
    }

    /// The CRC-32 of gzip (the reflected polynomial 0xEDB88320).
    package static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        var index = 0
        // 5552 is the most bytes the sums take before they must be reduced.
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)
            while index < end {
                a &+= UInt32(bytes[index])
                b &+= a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
        return (b << 16) | a
    }

    // MARK: - Wrapping

    private enum Wrapping {
        case gzip
        case zlib
    }

    private static func readHeader(_ reader: inout BitReader) throws -> Wrapping {
        let first = try reader.byte()
        let second = try reader.byte()
        if first == 0x1F, second == 0x8B {
            let method = try reader.byte()
            let flags = try reader.byte()
            // Deflate is the only method, and the three high flag bits are reserved.
            guard method == 8, flags & 0xE0 == 0 else {
                throw PMTilesFormatError.corruptCompressedData
            }
            // The modification time, the extra flags and the operating system.
            try reader.skip(6)
            if flags & 0x04 != 0 {
                let low = try reader.byte()
                let high = try reader.byte()
                try reader.skip(Int(low) | Int(high) << 8)
            }
            // The file name, then the comment, each ending in a zero byte.
            for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
                while try reader.byte() != 0 {}
            }
            if flags & 0x02 != 0 {
                try reader.skip(2)
            }
            return .gzip
        }
        // A zlib header: deflate with a window of at most 32 KiB, no preset
        // dictionary, and the two bytes a multiple of 31.
        let header = Int(first) << 8 | Int(second)
        guard first & 0x0F == 8, first >> 4 <= 7, second & 0x20 == 0, header % 31 == 0 else {
            throw PMTilesFormatError.corruptCompressedData
        }
        return .zlib
    }

    private static func verifyTrailer(_ reader: inout BitReader, wrapping: Wrapping, output: [UInt8]) throws {
        reader.alignToByte()
        switch wrapping {
        case .gzip:
            let checksum = try reader.littleEndianUInt32()
            let byteCount = try reader.littleEndianUInt32()
            guard checksum == crc32(output), byteCount == UInt32(truncatingIfNeeded: output.count) else {
                throw PMTilesFormatError.corruptCompressedData
            }
        case .zlib:
            var checksum: UInt32 = 0
            for _ in 0..<4 {
                checksum = checksum << 8 | UInt32(try reader.byte())
            }
            guard checksum == adler32(output) else {
                throw PMTilesFormatError.corruptCompressedData
            }
        }
    }

    // MARK: - Deflate

    private static func inflateBlocks(_ reader: inout BitReader,
                                      into output: inout [UInt8],
                                      maximumOutputByteCount: Int) throws {
        var isLast = false
        repeat {
            isLast = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0:
                try inflateStored(&reader, into: &output, maximumOutputByteCount: maximumOutputByteCount)
            case 1:
                try inflateCodes(&reader, into: &output, maximumOutputByteCount: maximumOutputByteCount,
                                 literals: fixedLiteralCode, distances: fixedDistanceCode)
            case 2:
                let (literals, distances) = try readDynamicCodes(&reader)
                try inflateCodes(&reader, into: &output, maximumOutputByteCount: maximumOutputByteCount,
                                 literals: literals, distances: distances)
            default:
                throw PMTilesFormatError.corruptCompressedData
            }
        } while !isLast
    }

    private static func inflateStored(_ reader: inout BitReader,
                                      into output: inout [UInt8],
                                      maximumOutputByteCount: Int) throws {
        reader.alignToByte()
        let length = Int(try reader.byte()) | Int(try reader.byte()) << 8
        let complement = Int(try reader.byte()) | Int(try reader.byte()) << 8
        guard length == ~complement & 0xFFFF else {
            throw PMTilesFormatError.corruptCompressedData
        }
        guard output.count + length <= maximumOutputByteCount else {
            throw PMTilesFormatError.decompressedDataTooLarge
        }
        output.append(contentsOf: try reader.bytes(length))
    }

    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                                            35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtraBits: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                                                 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                                              257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                                              8193, 12289, 16385, 24577]
    private static let distanceExtraBits: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
                                                   7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static func inflateCodes(_ reader: inout BitReader,
                                     into output: inout [UInt8],
                                     maximumOutputByteCount: Int,
                                     literals: HuffmanCode,
                                     distances: HuffmanCode) throws {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                guard output.count < maximumOutputByteCount else {
                    throw PMTilesFormatError.decompressedDataTooLarge
                }
                output.append(UInt8(symbol))
                continue
            }
            if symbol == 256 {
                return
            }
            let lengthIndex = symbol - 257
            guard lengthIndex < lengthBase.count else {
                throw PMTilesFormatError.corruptCompressedData
            }
            let length = lengthBase[lengthIndex] + (try reader.bits(lengthExtraBits[lengthIndex]))
            let distanceIndex = try distances.decode(&reader)
            guard distanceIndex < distanceBase.count else {
                throw PMTilesFormatError.corruptCompressedData
            }
            let distance = distanceBase[distanceIndex] + (try reader.bits(distanceExtraBits[distanceIndex]))
            guard distance <= output.count else {
                throw PMTilesFormatError.corruptCompressedData
            }
            guard output.count + length <= maximumOutputByteCount else {
                throw PMTilesFormatError.decompressedDataTooLarge
            }
            // Byte by byte: the copy may run into the bytes it writes.
            var source = output.count - distance
            for _ in 0..<length {
                output.append(output[source])
                source += 1
            }
        }
    }

    /// The order the code length code lengths are sent in.
    private static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private static func readDynamicCodes(_ reader: inout BitReader) throws -> (HuffmanCode, HuffmanCode) {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeLengthCount = try reader.bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else {
            throw PMTilesFormatError.corruptCompressedData
        }

        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[index]] = try reader.bits(3)
        }
        let codeLengthCode = HuffmanCode(lengths: codeLengthLengths[...])
        guard codeLengthCode.unusedCodes == 0 else {
            throw PMTilesFormatError.corruptCompressedData
        }

        // The literal and the distance lengths, run-length coded as one list.
        var lengths = [Int](repeating: 0, count: literalCount + distanceCount)
        var index = 0
        while index < lengths.count {
            let symbol = try codeLengthCode.decode(&reader)
            if symbol < 16 {
                lengths[index] = symbol
                index += 1
                continue
            }
            var repeated = 0
            var count = 0
            switch symbol {
            case 16:
                guard index > 0 else {
                    throw PMTilesFormatError.corruptCompressedData
                }
                repeated = lengths[index - 1]
                count = 3 + (try reader.bits(2))
            case 17:
                count = 3 + (try reader.bits(3))
            default:
                count = 11 + (try reader.bits(7))
            }
            guard index + count <= lengths.count else {
                throw PMTilesFormatError.corruptCompressedData
            }
            for _ in 0..<count {
                lengths[index] = repeated
                index += 1
            }
        }
        // Without an end-of-block code the block could never end.
        guard lengths[256] != 0 else {
            throw PMTilesFormatError.corruptCompressedData
        }

        // An over-subscribed code is corrupt. An incomplete one is allowed
        // only when it has at most a single code, which deflate writes for a
        // block with one distance, or with none at all.
        let literals = HuffmanCode(lengths: lengths[..<literalCount])
        let distances = HuffmanCode(lengths: lengths[literalCount...])
        for code in [literals, distances] {
            guard code.unusedCodes == 0 || (code.unusedCodes > 0 && code.symbols.count <= 1) else {
                throw PMTilesFormatError.corruptCompressedData
            }
        }
        return (literals, distances)
    }

    private static let fixedLiteralCode: HuffmanCode = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        return HuffmanCode(lengths: lengths[...])
    }()

    private static let fixedDistanceCode = HuffmanCode(lengths: [Int](repeating: 5, count: 30)[...])

    /// A canonical Huffman code: how many codes there are of each length, and
    /// the symbols in the order of their codes.
    private struct HuffmanCode {
        static let maximumLength = 15

        var counts = [Int](repeating: 0, count: maximumLength + 1)
        var symbols: [Int] = []
        /// The code space the lengths leave unused: zero for a complete code,
        /// negative for an over-subscribed one.
        var unusedCodes = 0

        init(lengths: ArraySlice<Int>) {
            for length in lengths {
                counts[length] += 1
            }
            counts[0] = 0
            var left = 1
            for length in 1...Self.maximumLength {
                left <<= 1
                left -= counts[length]
                if left < 0 { break }
            }
            unusedCodes = left

            var offsets = [Int](repeating: 0, count: Self.maximumLength + 2)
            for length in 1...Self.maximumLength {
                offsets[length + 1] = offsets[length] + counts[length]
            }
            symbols = [Int](repeating: 0, count: offsets[Self.maximumLength + 1])
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1...Self.maximumLength {
                code |= try reader.bits(1)
                let count = counts[length]
                if code - count < first {
                    return symbols[index + (code - first)]
                }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw PMTilesFormatError.corruptCompressedData
        }
    }

    /// Reads the input a bit at a time from the low end of each byte, as
    /// deflate packs it. Running out of input is a truncated stream.
    private struct BitReader {
        let bytes: UnsafeBufferPointer<UInt8>
        var position = 0
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
        }

        /// The next `count` bits, at most 16, the first one read lowest.
        mutating func bits(_ count: Int) throws -> Int {
            while bitCount < count {
                guard position < bytes.count else {
                    throw PMTilesFormatError.corruptCompressedData
                }
                bitBuffer |= UInt32(bytes[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            let value = bitBuffer & ((1 << UInt32(count)) - 1)
            bitBuffer >>= UInt32(count)
            bitCount -= count
            return Int(value)
        }

        /// Drops the rest of the byte being read. `bits` never holds more
        /// than a part of one byte between calls that leave it aligned.
        mutating func alignToByte() {
            bitBuffer = 0
            bitCount = 0
        }

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else {
                throw PMTilesFormatError.corruptCompressedData
            }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func bytes(_ count: Int) throws -> UnsafeBufferPointer<UInt8> {
            guard count <= bytes.count - position else {
                throw PMTilesFormatError.corruptCompressedData
            }
            defer { position += count }
            return UnsafeBufferPointer(rebasing: bytes[position..<position + count])
        }

        mutating func skip(_ count: Int) throws {
            _ = try bytes(count)
        }

        mutating func littleEndianUInt32() throws -> UInt32 {
            var value: UInt32 = 0
            for shift in stride(from: UInt32(0), to: 32, by: 8) {
                value |= UInt32(try byte()) << shift
            }
            return value
        }
    }
}
