// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import XCTest
@testable import ImmersiveMap

/// The pins' atlases on the recording device: pictures share slots by
/// identity, the least recently used slot goes first, and a counter with no
/// picture gets no slot.
final class PinTextureAtlasTests: XCTestCase {
    private let device = RecordingGPUDevice()

    /// Pins with the same image share one atlas slot.
    func testPinsSharingImageShareOneSlot() throws {
        let atlas = PinTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        let image = Self.makeImage(gray: 0x80)
        atlas.beginFrame(1)

        let first = try XCTUnwrap(atlas.uploadImage(image))
        let second = try XCTUnwrap(atlas.slot(for: image))
        XCTAssertEqual(first.uvRect, second.uvRect)
        XCTAssertEqual(first.pageIndex, second.pageIndex)
        // Re-uploading the same image does not take a new slot.
        let reuploaded = try XCTUnwrap(atlas.uploadImage(image))
        XCTAssertEqual(reuploaded.uvRect, first.uvRect)
    }

    /// The atlas is a 2D array texture of the cells' pages, and an upload
    /// writes one cell of one page.
    func testAnUploadWritesItsCellOfItsPage() throws {
        let atlas = PinTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 2)
        let texture = try XCTUnwrap(atlas.textureArray as? RecordingTexture)
        XCTAssertEqual(texture.type, .type2DArray)
        XCTAssertEqual(texture.arrayLength, 2)
        XCTAssertEqual(texture.format, .bgra8Unorm)

        atlas.beginFrame(1)
        let slot = try XCTUnwrap(atlas.uploadImage(Self.makeImage(gray: 0x40)))
        let region = try XCTUnwrap(texture.replacedRegions.last)
        XCTAssertEqual(region.x, slot.cellX * 64)
        XCTAssertEqual(region.y, slot.cellY * 64)
        XCTAssertEqual(region.width, 64)
        XCTAssertEqual(region.height, 64)
        XCTAssertEqual(region.slice, slot.pageIndex)
    }

    /// An overflowing atlas evicts the slot of an image not used in
    /// the current frame and doesn't touch the current frame's slots.
    func testLRUEvictionPrefersImagesUnusedThisFrame() throws {
        // 2x2 slots.
        let atlas = PinTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        XCTAssertEqual(atlas.slotCapacity, 4)
        let images = (0..<5).map { Self.makeImage(gray: UInt8(0x10 * ($0 + 1))) }

        atlas.beginFrame(1)
        for index in 0..<4 {
            XCTAssertNotNil(atlas.uploadImage(images[index]), "image \(index)")
        }

        // Frame 2: images 1..3 are used, image 0 is untouched.
        atlas.beginFrame(2)
        for index in 1..<4 {
            XCTAssertNotNil(atlas.slot(for: images[index]))
        }
        // The fifth image evicts image zero (last used in frame 1).
        XCTAssertNotNil(atlas.uploadImage(images[4]))
        XCTAssertNil(atlas.slot(for: images[0]), "evicted")
        for index in 1..<5 {
            XCTAssertNotNil(atlas.slot(for: images[index]), "image \(index) is still there")
        }
    }

    /// An atlas fully occupied by the current frame's images does not evict them.
    func testFullAtlasOfCurrentFrameImagesRefusesUpload() throws {
        let atlas = PinTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        let images = (0..<5).map { Self.makeImage(gray: UInt8(0x20 * ($0 + 1))) }

        atlas.beginFrame(1)
        for index in 0..<4 {
            XCTAssertNotNil(atlas.uploadImage(images[index]))
            _ = atlas.slot(for: images[index])
        }
        XCTAssertNil(atlas.uploadImage(images[4]),
                     "every slot is used by the current frame, so there is nothing to evict")
        for index in 0..<4 {
            XCTAssertNotNil(atlas.slot(for: images[index]))
        }
    }

    /// A picture in a cell stays alive while the cell holds it, so no new
    /// picture can come to its identity and be taken for it.
    func testASlotKeepsItsPictureAlive() throws {
        let atlas = PinTextureAtlas(device: device, atlasSize: 128, cellSize: 64, pagesMax: 1)
        atlas.beginFrame(1)
        weak var released: PinImage?
        do {
            let image = Self.makeImage(gray: 0x30)
            released = image
            XCTAssertNotNil(atlas.uploadImage(image))
        }
        XCTAssertNotNil(released, "the atlas holds the picture of its cell")
    }

    #if !canImport(CoreGraphics)
    /// Without the host's drawer a counter has no picture and no slot, and
    /// the atlas does not ask again.
    func testACounterWithNoPictureHasNoSlot() {
        let previous = PinPictureHost.drawer
        PinPictureHost.drawer = nil
        defer { PinPictureHost.drawer = previous }
        let atlas = PinCountBadgeAtlas(device: device, badgePixelSize: 46)
        XCTAssertNil(atlas.slot(for: PinCountBadge(count: 3)))
        XCTAssertNil(atlas.slot(for: PinCountBadge(count: 3)))
    }

    /// The host's counter picture fills the counter's cell.
    func testTheHostsCounterPictureFillsItsCell() throws {
        let drawer = BadgeDrawer()
        let previous = PinPictureHost.drawer
        PinPictureHost.drawer = drawer
        defer { PinPictureHost.drawer = previous }
        let atlas = PinCountBadgeAtlas(device: device, badgePixelSize: 46)
        let slot = try XCTUnwrap(atlas.slot(for: PinCountBadge(count: 21)))
        XCTAssertEqual(drawer.texts, ["21"])
        let texture = try XCTUnwrap(atlas.texture as? RecordingTexture)
        let region = try XCTUnwrap(texture.replacedRegions.last)
        // Count 21 is cell 20: the first of the second row of 20.
        XCTAssertEqual(region.x, 0)
        XCTAssertEqual(region.y, 46)
        XCTAssertEqual(slot.uvRect.y, Float(46) / Float(texture.height), accuracy: 1e-6)
        _ = atlas.slot(for: PinCountBadge(count: 21))
        XCTAssertEqual(drawer.texts, ["21"], "a counter is drawn once")
    }
    #endif

    private static func makeImage(gray: UInt8) -> PinImage {
        PinImage(width: 4, height: 4, premultipliedBGRA: [UInt8](repeating: gray, count: 4 * 4 * 4))
    }
}

#if !canImport(CoreGraphics)
private final class BadgeDrawer: PinPictureDrawing, @unchecked Sendable {
    private(set) var texts: [String] = []

    func coverage(of parts: [PinShapePath], side: Int, margin: Double) -> [Bool]? { nil }

    func countBadge(text: String, side: Int) -> PinImage? {
        texts.append(text)
        return PinImage(width: side, height: side, premultipliedBGRA: [UInt8](repeating: 255, count: side * side * 4))
    }

    func placeholder(side: Int) -> PinImage? { nil }
}
#endif
