// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

extension LayerMesh {
    /// How long a load from a mesh's file may take before the file is read
    /// the ordinary way instead.
    static let fileLoadTimeout: TimeInterval = 5

    /// Metal's fast path: the device's IO queue loads the blocks straight
    /// from the file into the buffers, in one command buffer, where there
    /// is such a queue (not in the iOS Simulator, nor on a device without
    /// Metal 3). False when the file could not be opened, the load ended in
    /// error, or the queue did not answer in time.
    static func metalFileLoader(device: MTLDevice) -> FileLoader {
        { blocks, fileURL in
#if targetEnvironment(simulator)
            return false
#else
            guard let queue = MetalIOCommandQueues.shared(for: device),
                  let fileHandle = try? device.makeIOFileHandle(url: fileURL) else {
                return false
            }
            let commandBuffer = queue.makeCommandBuffer()
            for (buffer, range) in blocks {
                commandBuffer.load(buffer.metalBuffer,
                                   offset: 0,
                                   size: range.count,
                                   sourceHandle: fileHandle,
                                   sourceHandleOffset: range.lowerBound)
            }
            let completed: Bool? = await CallbackTimeout.await(seconds: fileLoadTimeout) { complete in
                commandBuffer.addCompletedHandler { completedBuffer in
                    complete(completedBuffer.status == .complete)
                }
                commandBuffer.commit()
            }
            if completed == nil {
                // Best effort: the ordinary read that follows writes the
                // same bytes a late answer would.
                commandBuffer.tryCancel()
            }
            return completed == true
#endif
        }
    }
}
