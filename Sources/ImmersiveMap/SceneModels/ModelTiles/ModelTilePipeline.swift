// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The pipelines the models of the model tiles draw with (ModelTile.metal):
/// the opaque world-pass pipeline, its variant that drops the fragments
/// below the ground for a tile coming up out of it, and the shadow caster
/// pipeline, over the vertex a model tile carries, in the tile's space.
final class ModelTilePipeline {
    let pipelineState: any GPURenderPipeline
    /// The opaque pipeline with `kModelTileClipsBelowGround` on: the draw
    /// of a tile still rising out of the ground (`ExtrusionRise`).
    let belowGroundClippedPipelineState: any GPURenderPipeline
    /// Depth-only replay into the shadow map.
    let shadowPipelineState: any GPURenderPipeline
    let baseColorSampler: any GPUSampler

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        // The vertex of a model tile, as the baker wrote it.
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float3, offset: 0, bufferIndex: 0)
        layout.attributes[1] = GPUVertexAttribute(format: .char3Normalized,
                                                  offset: ModelTileContents.normalOffset, bufferIndex: 0)
        layout.attributes[2] = GPUVertexAttribute(format: .uchar,
                                                  offset: ModelTileContents.layerOffset, bufferIndex: 0)
        layout.attributes[3] = GPUVertexAttribute(format: .ushort2Normalized,
                                                  offset: ModelTileContents.textureCoordinateOffset, bufferIndex: 0)
        layout.strides[0] = ModelTileContents.vertexStride

        func main(clipsBelowGround: Bool) -> GPURenderPipelineDescriptor {
            var descriptor = GPURenderPipelineDescriptor(
                vertexFunction: GPUShaderFunction(name: "modelTileVertexShader"),
                fragmentFunction: GPUShaderFunction(name: "modelTileFragmentShader",
                                                    constants: [0: .bool(clipsBelowGround)]),
                colorTargets: [GPUColorTarget(format: pixelFormat)])
            descriptor.label = clipsBelowGround ? "ModelTilesClippedBelowGround" : "ModelTiles"
            descriptor.vertexLayout = layout
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            return descriptor
        }

        // The caster pass writes a plain 2D depth attachment, one shadow
        // window: no colour, no fragment function, one sample.
        var casters = GPURenderPipelineDescriptor(
            vertexFunction: GPUShaderFunction(name: "modelTileShadowVertexShader"),
            fragmentFunction: nil,
            colorTargets: [])
        casters.label = "ModelTileCasters"
        casters.vertexLayout = layout
        casters.depthStencilFormat = ShadowCascadeAtlas.depthFormat
        casters.sampleCount = 1

        // The array has no repeat: a model tile's texture coordinates stay
        // inside the unit square, so the edge is clamped and a layer never
        // wraps into its own far side.
        var samplerDescriptor = GPUSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.addressModeU = .clampToEdge
        samplerDescriptor.addressModeV = .clampToEdge
        // A facade is seen at a slant more often than head on.
        samplerDescriptor.maxAnisotropy = 4

        do {
            pipelineState = try device.makeRenderPipeline(main(clipsBelowGround: false))
            belowGroundClippedPipelineState = try device.makeRenderPipeline(main(clipsBelowGround: true))
            shadowPipelineState = try device.makeRenderPipeline(casters)
        } catch {
            fatalError("Failed to create the model tile pipelines: \(error)")
        }
        guard let sampler = device.makeSampler(samplerDescriptor) else {
            fatalError("Failed to create the model tiles' sampler")
        }
        self.baseColorSampler = sampler
    }
}
