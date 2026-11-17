// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// Prepares per-tile flat world-space origin and size data for GPU screen projection.
/// Compute kernels use this payload to convert tile-local UV points into world/screen coordinates.
final class FlatTileOriginCalculator {
    private let tileOriginDataBufferStore: GPUFrameSlottedBuffer<FlatTileOriginData>
    private var tileOriginData: [FlatTileOriginData] = []

    var currentTileOriginData: [FlatTileOriginData] {
        tileOriginData
    }

    init(device: any GPUDevice) {
        self.tileOriginDataBufferStore = GPUFrameSlottedBuffer(device: device,
                                                               slotsCount: InFlightFramePool.inFlightFramesCount)
    }

    func update(slot: Int = 0,
                tiles: [VisibleTile],
                flatRenderState: FlatRenderState) -> any GPUBuffer {
        tileOriginData.removeAll(keepingCapacity: true)
        tileOriginData.reserveCapacity(tiles.count)
        tileOriginData = tiles.map { tile in
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.tile.x,
                                                                    y: tile.tile.y,
                                                                    z: tile.tile.z,
                                                                    worldWrap: tile.worldWrap,
                                                                    flatRenderPan: flatRenderState.pan,
                                                                    renderMapSize: flatRenderState.renderMapSize)
            return FlatTileOriginData(panRelativeOrigin: SIMD2<Float>(originAndSize.x, originAndSize.y),
                                      size: originAndSize.z)
        }

        let tileOriginDataBuffer = tileOriginDataBufferStore.ensureCapacity(slot: slot,
                                                                            count: max(1, tileOriginData.count))
        if tileOriginData.isEmpty == false {
            let bytesCount = tileOriginData.count * MemoryLayout<FlatTileOriginData>.stride
            tileOriginData.withUnsafeBytes { bytes in
                tileOriginDataBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytesCount)
            }
        }

        return tileOriginDataBuffer
    }
}
