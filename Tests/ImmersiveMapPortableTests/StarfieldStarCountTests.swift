// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import XCTest
@testable import ImmersiveMap

final class StarfieldStarCountTests: XCTestCase {
    func testZeroStarCountProducesEmptyModel() {
        XCTAssertTrue(StarfieldModel.makeStars(config: makeConfig(starCount: 0)).isEmpty)
    }

    func testNegativeStarCountProducesEmptyModel() {
        XCTAssertTrue(StarfieldModel.makeStars(config: makeConfig(starCount: -5)).isEmpty)
    }

    func testSmallStarCountsProduceExactlyRequestedStars() {
        for starCount in 1...24 {
            let stars = StarfieldModel.makeStars(config: makeConfig(starCount: starCount))
            XCTAssertEqual(stars.count, starCount, "starCount \(starCount)")
        }
    }

    func testDefaultStarCountProducesExactlyRequestedStars() {
        let config = ImmersiveMapSettings.default.scene.starfield
        XCTAssertEqual(StarfieldModel.makeStars(config: config).count, config.starCount)
    }

    /// The regression from issue #17: `makeBuffer(bytes:length:)` returns nil for a zero
    /// length, and the renderer used to force unwrap it. An empty model must produce no
    /// buffer so the star pass can be skipped.
    func testEmptyStarsProduceNoVertexBuffer() {
        XCTAssertNil(StarfieldRenderer.makeVerticesBuffer(device: RecordingGPUDevice(), stars: []))
    }

    /// The same path the renderer takes, from config through the model to the buffer.
    func testZeroStarCountConfigProducesNoVertexBuffer() {
        let stars = StarfieldModel.makeStars(config: makeConfig(starCount: 0))
        XCTAssertNil(StarfieldRenderer.makeVerticesBuffer(device: RecordingGPUDevice(), stars: stars))
    }

    func testNonEmptyStarsProduceVertexBufferCoveringEveryStar() throws {
        let stars = StarfieldModel.makeStars(config: makeConfig(starCount: 7))
        XCTAssertEqual(stars.count, 7)

        let buffer = try XCTUnwrap(StarfieldRenderer.makeVerticesBuffer(device: RecordingGPUDevice(),
                                                                       stars: stars))
        XCTAssertEqual(buffer.length % stars.count, 0)
        XCTAssertGreaterThanOrEqual(buffer.length, stars.count)
    }


    private func makeConfig(starCount: Int) -> ImmersiveMapSettings.StarfieldSettings {
        var config = ImmersiveMapSettings.default.scene.starfield
        config.starCount = starCount
        return config
    }
}
