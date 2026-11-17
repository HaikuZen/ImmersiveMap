// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The world-pass pipelines of the scene models: one opaque pipeline every
/// model draws with (textured and constant-color submeshes share it,
/// untextured ones bind `whiteTexture`), its variant that drops the
/// fragments below the ground and the stencil-only footprint pipeline, the
/// two the ground cut adds (see SceneModel.metal), and the shadow caster
/// pipeline.
final class SceneModelPipeline {
    let pipelineState: any GPURenderPipeline
    /// The opaque pipeline with `kSceneModelClipsBelowGround` on: the second
    /// draw of a model that cuts into the ground, outside its ground hole.
    let belowGroundClippedPipelineState: any GPURenderPipeline
    /// The model flattened onto the ground plane, writing neither colour
    /// nor depth: the draw that raises or lowers the ground hole bit.
    let groundFootprintPipelineState: any GPURenderPipeline
    /// Depth-only replay into the shadow map: no color attachments and no
    /// fragment function, the rasterizer writes bare depth.
    let shadowPipelineState: any GPURenderPipeline
    let baseColorSampler: any GPUSampler
    let whiteTexture: any GPUTexture

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        // The canonical interleaved layout produced by SceneModelAssetLoader.
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float3, offset: 0, bufferIndex: 0)
        layout.attributes[1] = GPUVertexAttribute(format: .float3, offset: SceneModelVertexLayout.normalOffset, bufferIndex: 0)
        layout.attributes[2] = GPUVertexAttribute(format: .float2, offset: SceneModelVertexLayout.uvOffset, bufferIndex: 0)
        layout.strides[0] = SceneModelVertexLayout.stride

        func main(clipsBelowGround: Bool) -> GPURenderPipelineDescriptor {
            var descriptor = GPURenderPipelineDescriptor(
                vertexFunction: GPUShaderFunction(name: "sceneModelVertexShader"),
                fragmentFunction: GPUShaderFunction(name: "sceneModelFragmentShader",
                                                    constants: [0: .bool(clipsBelowGround)]),
                colorTargets: [GPUColorTarget(format: pixelFormat)])
            descriptor.label = clipsBelowGround ? "SceneModelsClippedBelowGround" : "SceneModels"
            descriptor.vertexLayout = layout
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            return descriptor
        }

        // Stencil only: the colour target is the world pass's, masked off,
        // and no fragment function runs. The depth-stencil state of the
        // draw keeps the depth untouched.
        var maskedColor = GPUColorTarget(format: pixelFormat)
        maskedColor.writesColor = false
        var footprint = GPURenderPipelineDescriptor(
            vertexFunction: GPUShaderFunction(name: "sceneModelGroundFootprintVertexShader"),
            fragmentFunction: nil,
            colorTargets: [maskedColor])
        footprint.label = "SceneModelGroundFootprint"
        footprint.vertexLayout = layout
        footprint.depthStencilFormat = .depth32FloatStencil8
        footprint.sampleCount = sampleCount

        // The caster pass writes a plain 2D depth attachment, one shadow
        // window: no colour, no fragment function, one sample.
        var casters = GPURenderPipelineDescriptor(
            vertexFunction: GPUShaderFunction(name: "sceneModelShadowVertexShader"),
            fragmentFunction: nil,
            colorTargets: [])
        casters.label = "SceneModelCasters"
        casters.vertexLayout = layout
        casters.depthStencilFormat = ShadowCascadeAtlas.depthFormat
        casters.sampleCount = 1

        var samplerDescriptor = GPUSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.addressModeU = .repeat
        samplerDescriptor.addressModeV = .repeat

        var white = GPUTextureDescriptor(format: .rgba8Unorm, width: 1, height: 1)
        white.usage = .shaderRead
        do {
            pipelineState = try device.makeRenderPipeline(main(clipsBelowGround: false))
            belowGroundClippedPipelineState = try device.makeRenderPipeline(main(clipsBelowGround: true))
            groundFootprintPipelineState = try device.makeRenderPipeline(footprint)
            shadowPipelineState = try device.makeRenderPipeline(casters)
        } catch {
            fatalError("Failed to create the scene model pipelines: \(error)")
        }
        guard let sampler = device.makeSampler(samplerDescriptor),
              let whiteTexture = device.makeTexture(white) else {
            fatalError("Failed to create the scene models' sampler and white texture")
        }
        let whitePixel: [UInt8] = [255, 255, 255, 255]
        whitePixel.withUnsafeBytes { bytes in
            whiteTexture.replace(x: 0, y: 0, width: 1, height: 1, mipmapLevel: 0, slice: 0,
                                 bytes: bytes.baseAddress!, bytesPerRow: 4)
        }
        self.baseColorSampler = sampler
        self.whiteTexture = whiteTexture
    }

    func selectPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(pipelineState)
    }

    func selectBelowGroundClippedPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(belowGroundClippedPipelineState)
    }

    func selectGroundFootprintPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(groundFootprintPipelineState)
    }

    func selectShadowPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(shadowPipelineState)
    }
}
