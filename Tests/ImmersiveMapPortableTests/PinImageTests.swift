// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The pins' own picture type and the resampling that fits a picture of
/// pixels into an atlas cell, on every platform the engine builds.
final class PinImageTests: XCTestCase {
    func testStraightRGBAIsPremultipliedIntoBGRA() {
        let image = PinImage(width: 2, height: 1, rgba: [
            255, 128, 0, 255,
            200, 100, 50, 128
        ])
        guard case .pixels(let pixels) = image.storage else {
            return XCTFail("A picture of pixels holds its pixels")
        }
        XCTAssertEqual(Array(pixels[0..<4]), [0, 128, 255, 255])
        // 50 * 128 / 255, 100 * 128 / 255, 200 * 128 / 255, rounded.
        XCTAssertEqual(Array(pixels[4..<8]), [25, 50, 100, 128])
    }

    func testAPictureOfPixelsIsKnownToTheAtlasByItself() {
        let pixels = [UInt8](repeating: 255, count: 4)
        let first = PinImage(width: 1, height: 1, premultipliedBGRA: pixels)
        let second = PinImage(width: 1, height: 1, premultipliedBGRA: pixels)
        XCTAssertTrue(first.isSamePicture(as: first))
        XCTAssertFalse(first.isSamePicture(as: second),
                       "Equal pixels are two pictures: the atlas knows a picture by its identity")
    }

    func testThePinAndItsSourceCarryThePicture() {
        let image = PinImage(width: 1, height: 1, premultipliedBGRA: [1, 2, 3, 255])
        let pin = ImmersiveMapPin(id: 7,
                                  coordinate: GeoCoordinate(latitude: 1, longitude: 2),
                                  image: image)
        XCTAssertTrue(pin.image === image)
        XCTAssertNil(pin.imageSource.remoteURL)
    }

    func testARemotePictureShowsThePlaceholderUntilItLoads() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/pin.png"))
        let pin = ImmersiveMapPin(id: 1,
                                  coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                  image: .remote(url))
        XCTAssertEqual(pin.imageSource.remoteURL, url)
        XCTAssertTrue(pin.image === PinImage.defaultPlaceholder)
        XCTAssertGreaterThan(pin.image.width, 0)
    }

    func testResamplingToTheSameSizeKeepsThePixels() {
        let pixels: [UInt8] = (0..<16).map { UInt8($0 * 10) }
        XCTAssertEqual(PinPixelResampler.resample(pixels, width: 2, height: 2, toWidth: 2, height: 2), pixels)
    }

    func testShrinkingAveragesWhatEachPixelCovers() {
        // Four opaque pixels, two black and two white, become one grey one.
        let pixels: [UInt8] = [
            0, 0, 0, 255, 255, 255, 255, 255,
            255, 255, 255, 255, 0, 0, 0, 255
        ]
        let result = PinPixelResampler.resample(pixels, width: 2, height: 2, toWidth: 1, height: 1)
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[3], 255)
        for channel in 0..<3 {
            XCTAssertEqual(Int(result[channel]), 128, accuracy: 1)
        }
    }

    func testAPlainColourStaysPlainAtAnySize() {
        let texel: [UInt8] = [40, 80, 120, 200]
        let pixels = Array([[UInt8]](repeating: texel, count: 3 * 5).joined())
        for (width, height) in [(1, 1), (7, 2), (12, 20)] {
            let result = PinPixelResampler.resample(pixels, width: 3, height: 5, toWidth: width, height: height)
            XCTAssertEqual(result.count, width * height * 4)
            for index in stride(from: 0, to: result.count, by: 4) {
                XCTAssertEqual(Array(result[index..<index + 4]), texel, "\(width)x\(height) at \(index / 4)")
            }
        }
    }

    func testEveryTargetSamplesWeightsSumToOne() {
        for (source, target) in [(1, 9), (9, 1), (64, 48), (48, 64), (5, 5)] {
            for taps in PinPixelResampler.weights(from: source, to: target) {
                XCTAssertEqual(taps.reduce(0) { $0 + $1.1 }, 1, accuracy: 1e-5)
                XCTAssertTrue(taps.allSatisfy { $0.0 >= 0 && $0.0 < source })
            }
        }
    }
}
