// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

extension TreeModelMesh {
    /// How long a load from the file may take before the bytes are copied
    /// from memory instead: the file is a few kilobytes, so this is
    /// reached only by a request the driver never answers.
    static let fileLoadTimeout: TimeInterval = 15

    /// Metal's fast path: the device's IO queue reads the file straight into
    /// the buffer, where there is one (not in the iOS Simulator).
    static func metalFileLoader(device: MTLDevice) -> FileLoader {
        { buffer, fileURL, length in
#if targetEnvironment(simulator)
            return false
#else
            guard let queue = MetalIOCommandQueues.shared(for: device),
                  let fileHandle = try? device.makeIOFileHandle(url: fileURL) else {
                return false
            }
            let commandBuffer = queue.makeCommandBuffer()
            commandBuffer.load(buffer.metalBuffer, offset: 0, size: length, sourceHandle: fileHandle, sourceHandleOffset: 0)
            let completed: Bool? = await CallbackTimeout.await(seconds: fileLoadTimeout) { complete in
                commandBuffer.addCompletedHandler { completedBuffer in
                    complete(completedBuffer.status == .complete)
                }
                commandBuffer.commit()
            }
            if completed == nil {
                commandBuffer.tryCancel()
            }
            return completed == true
#endif
        }
    }
}
