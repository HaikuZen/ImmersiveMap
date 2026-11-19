// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import os
import PortableFoundation
import simd

enum PinTextureRasterizer {
    static let logger = Logger(subsystem: "ImmersiveMap", category: "Pins")

    /// A pin's picture as the atlas's texels, `width` by `height`,
    /// premultiplied BGRA, rows from the top: a picture of a `CGImage` drawn
    /// by Core Graphics as it always was, a picture of pixels resampled.
    static func makeBGRAData(for image: PinImage,
                             width: Int,
                             height: Int) -> [UInt8]? {
        switch image.storage {
        #if canImport(CoreGraphics)
        case .cgImage(let cgImage):
            return makeBGRAData(for: cgImage, width: width, height: height)
        #endif
        case .pixels(let pixels):
            if let warning = imageSizeWarning(sourceWidth: image.width,
                                              sourceHeight: image.height,
                                              targetWidth: width,
                                              targetHeight: height) {
                logger.warning("\(warning, privacy: .public)")
            }
            return PinPixelResampler.resample(pixels,
                                              width: image.width,
                                              height: image.height,
                                              toWidth: width,
                                              height: height)
        }
    }

    static func imageSizeWarning(sourceWidth: Int,
                                 sourceHeight: Int,
                                 targetWidth: Int,
                                 targetHeight: Int) -> String? {
        guard sourceWidth != targetWidth || sourceHeight != targetHeight else {
            return nil
        }

        return "Pin pin image size mismatch: source \(sourceWidth)x\(sourceHeight), expected \(targetWidth)x\(targetHeight); image will be resampled into the pin atlas."
    }
}

struct PinAtlasSlot {
    let pageIndex: Int
    let cellX: Int
    let cellY: Int
    let uvRect: SIMD4<Float>
}

/// Atlas of pin images. Slots are keyed by the picture's identity
/// (`PinImage.atlasKey`, the `CGImage`'s for a picture of one) rather than
/// pin id: thousands of pins sharing images share one slot. On overflow
/// the least recently used slot not touched by the current frame is evicted -
/// the atlas works as a cache of the visible scene.
final class PinTextureAtlas {
    private struct SlotState {
        var slot: PinAtlasSlot
        var lastUsedFrame: UInt64
    }

    private let atlasSize: Int
    private let cellSize: Int
    private let pagesMax: Int

    private(set) var textureArray: any GPUTexture
    private var freeSlots: [PinAtlasSlot] = []
    private var slotsByImage: [ObjectIdentifier: SlotState] = [:]
    private var currentFrame: UInt64 = 0

    init(device: any GPUDevice, atlasSize: Int, cellSize: Int, pagesMax: Int) {
        self.atlasSize = atlasSize
        self.cellSize = cellSize
        self.pagesMax = pagesMax
        precondition(atlasSize % cellSize == 0, "Atlas size must be divisible by pin cell size.")
        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: atlasSize, height: atlasSize)
        descriptor.type = .type2DArray
        descriptor.arrayLength = pagesMax
        descriptor.usage = .shaderRead
        descriptor.storage = .shared
        descriptor.label = "PinAtlas"
        guard let textureArray = device.makeTexture(descriptor) else {
            fatalError("Failed to create pin atlas texture array.")
        }
        self.textureArray = textureArray
        appendSlots()
    }

    var slotCapacity: Int {
        let cellsPerSide = atlasSize / cellSize
        return cellsPerSide * cellsPerSide * pagesMax
    }

    /// Frame-start mark: slot usage is tracked per frame, and slots used by
    /// the current frame are never evicted.
    func beginFrame(_ frameIndex: UInt64) {
        currentFrame = frameIndex
    }

    /// Slot of an already-uploaded image; marks it as used this frame.
    func slot(for image: PinImage) -> PinAtlasSlot? {
        let key = image.atlasKey
        guard var state = slotsByImage[key] else {
            return nil
        }
        if state.lastUsedFrame != currentFrame {
            state.lastUsedFrame = currentFrame
            slotsByImage[key] = state
        }
        return state.slot
    }

    /// Uploads the image into a free slot (or evicts the LRU one) and returns
    /// it; nil means the atlas is fully occupied by this frame's images.
    func uploadImage(_ image: PinImage) -> PinAtlasSlot? {
        let key = image.atlasKey
        if let existing = slotsByImage[key] {
            return existing.slot
        }
        guard let slot = takeSlot() else {
            return nil
        }
        guard let texels = PinTextureRasterizer.makeBGRAData(for: image,
                                                             width: cellSize,
                                                             height: cellSize)
        else {
            freeSlots.append(slot)
            return nil
        }

        texels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            textureArray.replace(x: slot.cellX * cellSize, y: slot.cellY * cellSize,
                                 width: cellSize, height: cellSize,
                                 mipmapLevel: 0, slice: slot.pageIndex,
                                 bytes: base, bytesPerRow: cellSize * 4)
        }
        slotsByImage[key] = SlotState(slot: slot, lastUsedFrame: currentFrame)
        return slot
    }

    private func takeSlot() -> PinAtlasSlot? {
        if let free = freeSlots.popLast() {
            return free
        }
        var oldestKey: ObjectIdentifier?
        var oldestFrame = UInt64.max
        for (key, state) in slotsByImage
        where state.lastUsedFrame < currentFrame && state.lastUsedFrame < oldestFrame {
            oldestKey = key
            oldestFrame = state.lastUsedFrame
        }
        guard let oldestKey, let evicted = slotsByImage.removeValue(forKey: oldestKey) else {
            return nil
        }
        return evicted.slot
    }

    private func appendSlots() {
        let cellsPerSide = atlasSize / cellSize
        let invSize = 1.0 / Float(atlasSize)
        for page in 0..<pagesMax {
            for y in 0..<cellsPerSide {
                for x in 0..<cellsPerSide {
                    let minX = Float(x * cellSize) * invSize
                    let minY = Float(y * cellSize) * invSize
                    let maxX = Float((x + 1) * cellSize) * invSize
                    let maxY = Float((y + 1) * cellSize) * invSize
                    freeSlots.append(PinAtlasSlot(pageIndex: page,
                                                     cellX: x,
                                                     cellY: y,
                                                     uvRect: SIMD4<Float>(minX, minY, maxX, maxY)))
                }
            }
        }
    }
}

struct PinCountBadgeAtlasSlot {
    let uvRect: SIMD4<Float>
}

/// Where a merged pin's counter picture comes from: Core Graphics on
/// Apple's platforms (`PinTextureRasterizer+CoreGraphics.swift`), the
/// host's drawer elsewhere (`PinPictureHost`), nil where there is none.
enum PinCountBadgePicture {
    static func make(_ key: PinCountBadgeKey, side: Int) -> PinImage? {
        #if canImport(CoreGraphics)
        return makeBadgeImage(for: key, side: side)
        #else
        return PinPictureHost.drawer?.countBadge(text: key.text, side: side)
        #endif
    }
}

/// Atlas of round bubble counters for merged pins: a white circle with the
/// number of merged pins; values above 999 are drawn as "999+". A counter
/// with no picture (no drawer off Apple's platforms) has no slot, and the
/// pin is drawn without it.
final class PinCountBadgeAtlas {
    static let maximumCount = PinCountBadgeKey.maximumCount

    private let cellSize: Int
    private let columns: Int
    private let rows: Int

    private(set) var texture: any GPUTexture
    private var slotsByKey: [PinCountBadgeKey: PinCountBadgeAtlasSlot] = [:]
    /// The counters that had no picture, asked for once.
    private var missingKeys: Set<PinCountBadgeKey> = []

    init(device: any GPUDevice,
         badgePixelSize: Int,
         columns: Int = 20) {
        self.cellSize = max(1, badgePixelSize)
        self.columns = max(1, columns)
        self.rows = (Self.maximumCount + 1 + self.columns - 1) / self.columns

        var descriptor = GPUTextureDescriptor(format: .bgra8Unorm,
                                              width: self.cellSize * self.columns,
                                              height: self.cellSize * self.rows)
        descriptor.usage = .shaderRead
        descriptor.storage = .shared
        descriptor.label = "PinCountBadgeAtlas"
        guard let texture = device.makeTexture(descriptor) else {
            fatalError("Failed to create pin count badge atlas texture.")
        }
        self.texture = texture
    }

    func slot(for badge: PinCountBadge) -> PinCountBadgeAtlasSlot? {
        let key = PinCountBadgeKey(badge)
        if let existing = slotsByKey[key] {
            return existing
        }
        guard missingKeys.contains(key) == false else {
            return nil
        }

        guard let image = PinCountBadgePicture.make(key, side: cellSize),
              let texels = PinTextureRasterizer.makeBGRAData(for: image,
                                                             width: cellSize,
                                                             height: cellSize) else {
            missingKeys.insert(key)
            return nil
        }

        let atlasIndex = key.atlasIndex
        let column = atlasIndex % columns
        let row = atlasIndex / columns
        let minX = column * cellSize
        let minY = row * cellSize
        texels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(x: minX, y: minY, width: cellSize, height: cellSize,
                            mipmapLevel: 0, slice: 0,
                            bytes: baseAddress, bytesPerRow: cellSize * 4)
        }

        let invWidth = 1.0 / Float(texture.width)
        let invHeight = 1.0 / Float(texture.height)
        let slot = PinCountBadgeAtlasSlot(
            uvRect: SIMD4<Float>(Float(minX) * invWidth,
                                 Float(minY) * invHeight,
                                 Float(minX + cellSize) * invWidth,
                                 Float(minY + cellSize) * invHeight)
        )
        slotsByKey[key] = slot
        return slot
    }
}
