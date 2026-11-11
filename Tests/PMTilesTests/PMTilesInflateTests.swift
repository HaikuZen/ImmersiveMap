// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import PMTiles
import PMTilesTestSupport
import XCTest

/// The Swift inflate against streams zlib wrote, kept here as bytes: every
/// platform runs these, the ones that inflate with zlib included, so the
/// decoder is checked where it is not the one in use.
final class PMTilesInflateTests: XCTestCase {
    /// What every stream but the short one holds.
    private static let text = Data((0..<200).map { "tile \($0) of the archive, layer \($0 % 7)\n" }.joined().utf8)
    private static let shortText = Data("hello hello hello hello".utf8)

    // zlib at level 9: a block of dynamic Huffman codes with matches.
    private static let dynamicBlock = Data(base64Encoded:
        "H4sIAAAAAAACA4XYS2ocQRBF0blXUQvwIF9kxm85wrSQQGAQjcG7N6bHFXf8Rpf+1Kl4fn49rnX9fr+eH4/r7fvXx+efx8/r" +
        "6+3v4/taP57/Z93Mes12M9tr3jfzfs3nZj6v2W9mf81xM8drzjms5rCew7TmMmlOk81t2nOcDnxsPucpoC+hr6Cv5z5bc59p" +
        "7jOD7+We++zMfeZznwX0JfQV9PXctxf88DT3bZv79p779pn7ts99O6Avoa+gr+e+s+a+o7nv2Nx39tx3ztx3HP45A/oS+gr6" +
        "eu7zNfe55j63uc83PBrO3Oc+93lAX0JfQV/PfbHmvhA8+2zuiz33xZn7wue+COhL6Cvoa3i4A1sS3JIAlwS5JNAlwS5JeAG9" +
        "JPAlwS8FfinwS4FfCvxS4JcCvxT4pcAvBX4p8EuDXxr80uCXBr80+KXBLw1+afBLg18a/KK1CNggGC0gjBYYRgsQowWK0QrK" +
        "TMosygTJSEAZCSwjAWYk0IwEnJGc3peCMpMyizLBNDJAjQxUIwPWyDa9FwJsZCAbWVBmUmZRJuhGG3ijLXr/BeBog3C0gTja" +
        "YBztoMykzKLMpvd8us8ckI4OUEcHrKMD2NEB7egEZSZlFmXSxcbpZON0s3E62jhdbRzPNnS3cTrcOF1unE43DvZRAH4UoB+F" +
        "0XkK/KMAAClAQIqgzKTMokxSUJKCkhSUpKAkBSUpKElBSQpKUlCSgpIUVKSgIgUVKahIQUUKKlJQkYKKFFSkoCIFNSmoSUFN" +
        "CmpSUJOCmhTUpKAmBTUpqO8V9A8HNOFEWhkAAA==")!

    // A short input, which zlib writes as a block of the fixed codes.
    private static let fixedBlock = Data(base64Encoded:
        "H4sIAAAAAAACA8tIzcnJV8hAJwHjUT2NFwAAAA==")!

    // The same text in zlib wrapping, with its Adler-32 trailer.
    private static let zlibStream = Data(base64Encoded:
        "eNqF2EtqHEEQRdG5V1EL8CBfZMZvOcK0kEBgEI3BuzemxxV3/EaX/tSpeH5+Pa51/X6/nh+P6+3718fnn8fP6+vt7+P7Wj+e" +
        "/2fdzHrNdjPba943837N52Y+r9lvZn/NcTPHa845rOawnsO05jJpTpPNbdpznA58bD7nKaAvoa+gr+c+W3Ofae4zg+/lnvvs" +
        "zH3mc58F9CX0FfT13LcX/PA0922b+/ae+/aZ+7bPfTugL6GvoK/nvrPmvqO579jcd/bcd87cdxz+OQP6EvoK+nru8zX3ueY+" +
        "t7nPNzwaztznPvd5QF9CX0Ffz32x5r4QPPts7os998WZ+8LnvgjoS+gr6Gt4uANbEtySAJcEuSTQJcEuSXgBvSTwJcEvBX4p" +
        "8EuBXwr8UuCXAr8U+KXALwV+KfBLg18a/NLglwa/NPilwS8NfmnwS4NfGvyitQjYIBgtIIwWGEYLEKMFitEKykzKLMoEyUhA" +
        "GQksIwFmJNCMBJyRnN6XgjKTMosywTQyQI0MVCMD1sg2vRcCbGQgG1lQZlJmUSboRht4oy16/wXgaINwtIE42mAc7aDMpMyi" +
        "zKb3fLrPHJCODlBHB6yjA9jRAe3oBGUmZRZl0sXG6WTjdLNxOto4XW0czzZ0t3E63DhdbpxONw72UQB+FKAfhdF5CvyjAAAp" +
        "QECKoMykzKJMUlCSgpIUlKSgJAUlKShJQUkKSlJQkoKSFFSkoCIFFSmoSEFFCipSUJGCihRUpKAiBTUpqElBTQpqUlCTgpoU" +
        "1KSgJgU1KajvFfQPZOIkHw==")!

    // Huffman coding only: a dynamic block with literals and no distance.
    private static let literalsOnly = Data(base64Encoded:
        "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" +
        "AA==")!

    // A gzip header with every optional field: extra, name, comment, CRC.
    private static let everyHeaderField = Data(base64Encoded:
        "H4sIHgAAAAAA/wUAZXh0cmF0aWxlLm12dABhIGNvbW1lbnQAKpyF2EtqHEEQRdG5V1EL8CBfZMZvOcK0kEBgEI3BuzemxxV3" +
        "/EaX/tSpeH5+Pa51/X6/nh+P6+3718fnn8fP6+vt7+P7Wj+e/2fdzHrNdjPba943837N52Y+r9lvZn/NcTPHa845rOawnsO0" +
        "5jJpTpPNbdpznA58bD7nKaAvoa+gr+c+W3Ofae4zg+/lnvvszH3mc58F9CX0FfT13LcX/PA0922b+/ae+/aZ+7bPfTugL6Gv" +
        "oK/nvrPmvqO579jcd/bcd87cdxz+OQP6EvoK+nru8zX3ueY+t7nPNzwaztznPvd5QF9CX0Ffz32x5r4QPPts7os998WZ+8Ln" +
        "vgjoS+gr6Gt4uANbEtySAJcEuSTQJcEuSXgBvSTwJcEvBX4p8EuBXwr8UuCXAr8U+KXALwV+KfBLg18a/NLglwa/NPilwS8N" +
        "fmnwS4NfGvyitQjYIBgtIIwWGEYLEKMFitEKykzKLMoEyUhAGQksIwFmJNCMBJyRnN6XgjKTMosywTQyQI0MVCMD1sg2vRcC" +
        "bGQgG1lQZlJmUSboRht4oy16/wXgaINwtIE42mAc7aDMpMyizKb3fLrPHJCODlBHB6yjA9jRAe3oBGUmZRZl0sXG6WTjdLNx" +
        "Oto4XW0czzZ0t3E63DhdbpxONw72UQB+FKAfhdF5CvyjAAApQECKoMykzKJMUlCSgpIUlKSgJAUlKShJQUkKSlJQkoKSFFSk" +
        "oCIFFSmoSEFFCipSUJGCihRUpKAiBTUpqElBTQpqUlCTgpoU1KSgJgU1KajvFfQPBzThRFoZAAA=")!

    private func inflate(_ data: Data, maximumOutputByteCount: Int = 1 << 20) throws -> Data {
        try PMTilesInflate.inflate(data, maximumOutputByteCount: maximumOutputByteCount)
    }

    func testADynamicHuffmanBlockInflates() throws {
        XCTAssertEqual(try inflate(Self.dynamicBlock), Self.text)
    }

    func testAFixedHuffmanBlockInflates() throws {
        XCTAssertEqual(try inflate(Self.fixedBlock), Self.shortText)
    }

    func testAZlibStreamInflates() throws {
        XCTAssertEqual(try inflate(Self.zlibStream), Self.text)
    }

    func testABlockWithNoDistanceCodeInflates() throws {
        XCTAssertEqual(try inflate(Self.literalsOnly), Self.text)
    }

    func testEveryOptionalHeaderFieldIsSkipped() throws {
        XCTAssertEqual(try inflate(Self.everyHeaderField), Self.text)
    }

    func testStoredBlocksInflateAcrossTheBlockLimit() throws {
        // More than one stored block holds, so the member has three.
        let original = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
        XCTAssertEqual(try inflate(PMTilesArchiveWriter.storedGzip(original, fileName: "tile.mvt")), original)
        XCTAssertEqual(try inflate(PMTilesArchiveWriter.storedGzip(Data())), Data())
    }

    func testWhatFollowsTheMemberIsLeftAlone() throws {
        XCTAssertEqual(try inflate(Self.dynamicBlock + Data([1, 2, 3])), Self.text)
    }

    func testAWrongChecksumThrows() {
        for stream in [Self.dynamicBlock, Self.zlibStream] {
            var wrong = stream
            // The first byte of the gzip CRC, the last of the Adler-32.
            wrong[wrong.count - (stream == Self.zlibStream ? 1 : 8)] ^= 0x01
            XCTAssertThrowsError(try inflate(wrong)) { error in
                XCTAssertEqual(error as? PMTilesFormatError, .corruptCompressedData)
            }
        }
    }

    func testEveryTruncationThrows() {
        for stream in [Self.dynamicBlock, Self.fixedBlock, Self.zlibStream, Self.everyHeaderField] {
            for length in 0..<stream.count {
                XCTAssertThrowsError(try inflate(stream.prefix(length)), "cut to \(length) bytes") { error in
                    XCTAssertEqual(error as? PMTilesFormatError, .corruptCompressedData)
                }
            }
        }
    }

    func testDamagedBytesNeverInflateToTheOriginal() {
        // A flipped bit is caught by the decoder or by the checksum: it
        // either throws or, in a header field nothing reads, changes nothing.
        for index in 0..<Self.dynamicBlock.count {
            var damaged = Self.dynamicBlock
            damaged[index] ^= 0x10
            if let output = try? inflate(damaged) {
                XCTAssertEqual(output, Self.text, "byte \(index)")
                XCTAssertLessThan(index, 10, "byte \(index) is past the header and was not caught")
            }
        }
    }

    func testOutputPastTheLimitThrows() {
        XCTAssertThrowsError(try inflate(Self.dynamicBlock, maximumOutputByteCount: Self.text.count - 1)) { error in
            XCTAssertEqual(error as? PMTilesFormatError, .decompressedDataTooLarge)
        }
        XCTAssertEqual(try inflate(Self.dynamicBlock, maximumOutputByteCount: Self.text.count), Self.text)
    }

    func testTheChecksumIsTheGzipCRC() {
        // The check value of CRC-32: the nine digits.
        XCTAssertEqual(PMTilesInflate.crc32(Array("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(PMTilesInflate.crc32([]), 0)
    }
}
