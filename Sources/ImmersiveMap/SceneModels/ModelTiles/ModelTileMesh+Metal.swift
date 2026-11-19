// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

extension ModelTileMesh {
    /// How long a load from the tile's file may take before the bytes are
    /// copied from memory instead. A tile is a few megabytes and a healthy
    /// load ends in milliseconds, so this is reached only by a request the
    /// driver never answers.
    static let fileLoadTimeout: TimeInterval = 15

    /// Metal's fast path: the device's IO queue loads the blocks from the
    /// tile's file straight into the buffers and the texture, in one
    /// command buffer, where there is a queue (not in the iOS Simulator,
    /// nor on a Mac without Metal 3). False when the file could not be
    /// opened, the load ended in error, or the queue did not answer in
    /// time.
    static func metalFileLoader(device: MTLDevice) -> FileLoader {
        { contents, fileURL, vertexBuffer, indexBuffer, texture in
#if targetEnvironment(simulator)
            return false
#else
            guard let queue = MetalIOCommandQueues.shared(for: device),
                  let fileHandle = try? device.makeIOFileHandle(url: fileURL) else {
                return false
            }
            let metalTexture = texture.metalTexture
            let commandBuffer = queue.makeCommandBuffer()
            commandBuffer.load(vertexBuffer.metalBuffer,
                               offset: 0,
                               size: contents.vertexRange.count,
                               sourceHandle: fileHandle,
                               sourceHandleOffset: contents.vertexRange.lowerBound)
            commandBuffer.load(indexBuffer.metalBuffer,
                               offset: 0,
                               size: contents.indexRange.count,
                               sourceHandle: fileHandle,
                               sourceHandleOffset: contents.indexRange.lowerBound)
            forEachTextureImage(of: contents) { level, layer, width, height, byteOffset, bytesPerRow, byteCount in
                commandBuffer.load(metalTexture,
                                   slice: layer,
                                   level: level,
                                   size: MTLSize(width: width, height: height, depth: 1),
                                   sourceBytesPerRow: bytesPerRow,
                                   sourceBytesPerImage: byteCount,
                                   destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                   sourceHandle: fileHandle,
                                   sourceHandleOffset: byteOffset)
            }
            let completed: Bool? = await CallbackTimeout.await(seconds: fileLoadTimeout) { complete in
                commandBuffer.addCompletedHandler { completedBuffer in
                    complete(completedBuffer.status == .complete)
                }
                commandBuffer.commit()
            }
            if completed == nil {
                // Best effort: the copy from memory that follows writes the
                // same bytes a late answer would.
                commandBuffer.tryCancel()
            }
            return completed == true
#endif
        }
    }
}
