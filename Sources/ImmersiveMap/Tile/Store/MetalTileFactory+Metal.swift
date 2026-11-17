// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

extension MetalTileFactory {
    /// How long one MTLIO load may take before the materialize gives up on
    /// it. A tile's container is a few megabytes at most and a healthy load
    /// ends in tens of milliseconds, so this is reached only by a request
    /// the driver never answers. The load then fails transiently: the pair
    /// on disk stays, the tile takes the network stage this once, and the
    /// next hit tries the queue again. Nothing is remembered across loads,
    /// because one slow answer (a saturated disk, a paused process) says
    /// nothing about the next.
    static let fileBlobLoadTimeout: TimeInterval = 15

    /// Metal's fast path: the device's IO queue loads a `.file` blob straight
    /// into the tile's buffer. Nil where there is no queue (the simulator,
    /// whose SDK has no MTLIO surface, and a Mac without Metal 3). The queue
    /// is resolved here, once: tile loads materialize concurrently from
    /// their own tasks, so a lazy creation would race.
    static func metalFileBlobLoader(device: MTLDevice) -> FileBlobLoader? {
#if targetEnvironment(simulator)
        return nil
#else
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: device),
              let queue = MetalIOCommandQueues.shared(for: device) else {
            return nil
        }
        return { url, format, buffer, byteCount in
            await loadFileBlob(from: url, format: format, into: buffer.metalBuffer,
                               byteCount: byteCount, device: device, queue: queue)
        }
#endif
    }

#if !targetEnvironment(simulator)
    /// Whether the load completed with the whole blob, false when the file
    /// could not be opened or the load ended in error, nil when the queue
    /// did not answer within `fileBlobLoadTimeout`. The completion handler
    /// is the only thing that resumes this await, and a load awaited without
    /// a deadline would hold its tile's disk slot for the rest of the
    /// process if the handler never ran; the loader's stage watchdog is the
    /// second line behind this one.
    private static func loadFileBlob(from url: URL,
                                     format: PreparedTileFileBlobFormat,
                                     into buffer: MTLBuffer,
                                     byteCount: Int,
                                     device: MTLDevice,
                                     queue: MTLIOCommandQueue) async -> Bool? {
        let fileHandle: MTLIOFileHandle?
        switch format {
        case .raw:
            fileHandle = try? device.makeIOFileHandle(url: url)
        case .lzfseContainer:
            fileHandle = try? device.makeIOFileHandle(url: url, compressionMethod: .lzfse)
        }
        guard let fileHandle else {
            return false
        }
        let ioCommandBuffer = queue.makeCommandBuffer()
        ioCommandBuffer.load(buffer,
                             offset: 0,
                             size: byteCount,
                             sourceHandle: fileHandle,
                             sourceHandleOffset: 0)
        let loaded: Bool? = await CallbackTimeout.await(seconds: fileBlobLoadTimeout) { complete in
            ioCommandBuffer.addCompletedHandler { completedBuffer in
                complete(completedBuffer.status == .complete)
            }
            ioCommandBuffer.commit()
        }
        if loaded == nil {
            // Best effort: a late answer is ignored either way, and the
            // buffer it would write is retained by the command buffer.
            ioCommandBuffer.tryCancel()
        }
        return loaded
    }
#endif
}

extension TileFileGeometry {
    /// Metal's file geometry: MTLIO containers written by
    /// `MTLIOPreparedTileGeometryTransport` and loaded by the device's IO
    /// queue. Nil where the queue is missing, so the session writes inline
    /// entries instead of a cache no hit could read.
    static func metal(device: MTLDevice, compressionEnabled: Bool) -> TileFileGeometry? {
        MetalTileFactory.metalFileBlobLoader(device: device).map {
            TileFileGeometry(transport: MTLIOPreparedTileGeometryTransport(compressionEnabled: compressionEnabled),
                             load: $0)
        }
    }
}
