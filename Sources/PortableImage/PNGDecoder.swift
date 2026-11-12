// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PMTiles
import PortableFoundation

/// An image as 8-bit RGBA, row after row from the top, no padding.
package struct RGBAImage: Equatable, Sendable {
    package let width: Int
    package let height: Int
    package let pixels: [UInt8]

    package init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4, "an RGBA image has four bytes a pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Reads a PNG, for the platforms without ImageIO: every colour type and bit
/// depth the format has, without interlacing. Apple's platforms decode with
/// ImageIO and never come here.
///
/// The image comes out as 8-bit RGBA with no colour management, its samples
/// as they are in the file: a terrain tile's samples are numbers, not
/// colours. A 16-bit sample is scaled to 8 bits with rounding, as Core
/// Graphics draws it, a grey one is copied to red, green and blue, and a
/// palette index is looked up, its alpha from `tRNS`.
package enum PNGDecoder {
    package enum Failure: Error, Equatable {
        case notPNG
        case truncated
        case badChecksum(chunk: String)
        case unsupported(String)
        case malformed(String)
    }

    /// The most bytes a decoded image may take: a corrupt header must not
    /// ask for gigabytes.
    package static let maximumPixelBytes = 256 * 1024 * 1024

    private static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    package static func decode(_ data: Data) throws -> RGBAImage {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, Array(bytes[0..<8]) == signature else {
            throw Failure.notPNG
        }
        var header: Header?
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var compressed: [UInt8] = []
        var offset = 8
        chunks: while true {
            guard offset + 12 <= bytes.count else {
                throw Failure.truncated
            }
            let length = Int(readUInt32(bytes, offset))
            let typeBytes = Array(bytes[offset + 4 ..< offset + 8])
            let type = String(decoding: typeBytes, as: UTF8.self)
            guard length <= bytes.count - offset - 12 else {
                throw Failure.truncated
            }
            let body = Array(bytes[offset + 8 ..< offset + 8 + length])
            let storedChecksum = readUInt32(bytes, offset + 8 + length)
            guard PMTilesInflate.crc32(typeBytes + body) == storedChecksum else {
                throw Failure.badChecksum(chunk: type)
            }
            offset += 12 + length
            switch type {
            case "IHDR":
                header = try Header(body)
            case "PLTE":
                palette = body
            case "tRNS":
                transparency = body
            case "IDAT":
                compressed += body
            case "IEND":
                break chunks
            default:
                // An unknown critical chunk (an upper case first letter)
                // changes how the image reads.
                if let first = typeBytes.first, first & 0x20 == 0 {
                    throw Failure.unsupported("critical chunk \(type)")
                }
            }
        }
        guard let header else {
            throw Failure.malformed("no IHDR")
        }
        guard header.width.multipliedReportingOverflow(by: header.height * 4).partialValue <= maximumPixelBytes,
              header.width <= maximumPixelBytes / max(1, header.height * 4) else {
            throw Failure.unsupported("an image of \(header.width)×\(header.height)")
        }
        let rowBytes = (header.width * header.bitsPerPixel + 7) / 8
        let expected = header.height * (rowBytes + 1)
        let filtered: [UInt8]
        do {
            filtered = [UInt8](try PMTilesInflate.inflate(Data(compressed), maximumOutputByteCount: expected,
                                                          expectedByteCount: expected))
        } catch {
            throw Failure.malformed("the image data does not inflate")
        }
        guard filtered.count == expected else {
            throw Failure.truncated
        }
        let rows = try unfilter(filtered, height: header.height, rowBytes: rowBytes,
                                bytesPerPixel: max(1, header.bitsPerPixel / 8))
        return try expand(rows, header: header, rowBytes: rowBytes, palette: palette, transparency: transparency)
    }

    private struct Header {
        let width: Int
        let height: Int
        let bitDepth: Int
        let colorType: Int

        var channels: Int {
            switch colorType {
            case 0, 3: return 1
            case 4: return 2
            case 2: return 3
            default: return 4
            }
        }

        var bitsPerPixel: Int { channels * bitDepth }

        init(_ body: [UInt8]) throws {
            guard body.count == 13 else {
                throw Failure.malformed("IHDR of \(body.count) bytes")
            }
            width = Int(readUInt32(body, 0))
            height = Int(readUInt32(body, 4))
            bitDepth = Int(body[8])
            colorType = Int(body[9])
            guard width > 0, height > 0 else {
                throw Failure.malformed("an empty image")
            }
            let allowed: [Int: Set<Int>] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
            guard allowed[colorType]?.contains(bitDepth) == true else {
                throw Failure.malformed("colour type \(colorType) at \(bitDepth) bits")
            }
            guard body[10] == 0, body[11] == 0 else {
                throw Failure.malformed("an unknown compression or filter method")
            }
            guard body[12] == 0 else {
                throw Failure.unsupported("an interlaced image")
            }
        }
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    /// The scanlines without their filter bytes, each filter undone against
    /// the line above, which starts as zeros.
    private static func unfilter(_ data: [UInt8], height: Int, rowBytes: Int, bytesPerPixel: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: height * rowBytes)
        for row in 0 ..< height {
            let filter = data[row * (rowBytes + 1)]
            let input = row * (rowBytes + 1) + 1
            let start = row * rowBytes
            for column in 0 ..< rowBytes {
                let raw = data[input + column]
                let left = column >= bytesPerPixel ? output[start + column - bytesPerPixel] : 0
                let up = row > 0 ? output[start - rowBytes + column] : 0
                let upLeft = row > 0 && column >= bytesPerPixel ? output[start - rowBytes + column - bytesPerPixel] : 0
                let predictor: UInt8
                switch filter {
                case 0: predictor = 0
                case 1: predictor = left
                case 2: predictor = up
                case 3: predictor = UInt8((Int(left) + Int(up)) / 2)
                case 4: predictor = paeth(left, up, upLeft)
                default: throw Failure.malformed("filter type \(filter)")
                }
                output[start + column] = raw &+ predictor
            }
        }
        return output
    }

    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    private static func expand(_ rows: [UInt8], header: Header, rowBytes: Int,
                               palette: [UInt8], transparency: [UInt8]) throws -> RGBAImage {
        let width = header.width, depth = header.bitDepth
        var pixels = [UInt8](repeating: 255, count: width * header.height * 4)
        // The `index`th sample of a row, scaled to 8 bits.
        func sample(_ row: Int, _ index: Int) -> UInt8 {
            let base = row * rowBytes
            switch depth {
            case 16:
                let value = Int(rows[base + index * 2]) << 8 | Int(rows[base + index * 2 + 1])
                return UInt8((value * 255 + 32767) / 65535)
            case 8:
                return rows[base + index]
            default:
                let bit = index * depth
                let byte = rows[base + bit / 8]
                let value = Int(byte >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
                return header.colorType == 3 ? UInt8(value) : UInt8(value * 255 / ((1 << depth) - 1))
            }
        }
        for y in 0 ..< header.height {
            for x in 0 ..< width {
                let out = (y * width + x) * 4
                switch header.colorType {
                case 0:
                    let grey = sample(y, x)
                    pixels[out] = grey; pixels[out + 1] = grey; pixels[out + 2] = grey
                case 2:
                    pixels[out] = sample(y, x * 3)
                    pixels[out + 1] = sample(y, x * 3 + 1)
                    pixels[out + 2] = sample(y, x * 3 + 2)
                case 3:
                    let index = Int(sample(y, x))
                    guard index * 3 + 2 < palette.count else {
                        throw Failure.malformed("palette index \(index) past the palette")
                    }
                    pixels[out] = palette[index * 3]
                    pixels[out + 1] = palette[index * 3 + 1]
                    pixels[out + 2] = palette[index * 3 + 2]
                    if index < transparency.count {
                        pixels[out + 3] = transparency[index]
                    }
                case 4:
                    let grey = sample(y, x * 2)
                    pixels[out] = grey; pixels[out + 1] = grey; pixels[out + 2] = grey
                    pixels[out + 3] = sample(y, x * 2 + 1)
                default:
                    pixels[out] = sample(y, x * 4)
                    pixels[out + 1] = sample(y, x * 4 + 1)
                    pixels[out + 2] = sample(y, x * 4 + 2)
                    pixels[out + 3] = sample(y, x * 4 + 3)
                }
            }
        }
        return RGBAImage(width: width, height: header.height, pixels: pixels)
    }
}
