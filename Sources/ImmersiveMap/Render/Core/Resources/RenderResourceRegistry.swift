// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The frame's shared GPU objects by name, set again each frame: what a
/// GPU capture or a diagnostic can find the frame's resources by.
final class RenderResourceRegistry {
    private(set) var frameIndex: UInt64 = 0
    private var buffers: [RenderResourceName: any GPUBuffer] = [:]
    private var textures: [RenderResourceName: any GPUTexture] = [:]
    private var pipelines: [RenderResourceName: any GPURenderPipeline] = [:]

    func beginFrame(frameIndex: UInt64) {
        self.frameIndex = frameIndex
        buffers.removeAll(keepingCapacity: true)
        textures.removeAll(keepingCapacity: true)
        pipelines.removeAll(keepingCapacity: true)
    }

    /// A buffer without a name of its own takes the registry's.
    func setBuffer(_ buffer: any GPUBuffer, named name: RenderResourceName) {
        if buffer.label == nil {
            buffer.label = name.rawValue
        }
        buffers[name] = buffer
    }

    /// The texture keeps the name it was made with (`GPUTextureDescriptor.label`).
    func setTexture(_ texture: any GPUTexture, named name: RenderResourceName) {
        textures[name] = texture
    }

    func setPipeline(_ pipeline: any GPURenderPipeline, named name: RenderResourceName) {
        pipelines[name] = pipeline
    }

    func buffer(named name: RenderResourceName) -> (any GPUBuffer)? {
        buffers[name]
    }

    func texture(named name: RenderResourceName) -> (any GPUTexture)? {
        textures[name]
    }

    func pipeline(named name: RenderResourceName) -> (any GPURenderPipeline)? {
        pipelines[name]
    }

    var counts: (buffers: Int, textures: Int, pipelines: Int) {
        (buffers.count, textures.count, pipelines.count)
    }
}
