// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The trees of the flat map (Trees.metal): the tree model drawn once per
/// instance of a tile, opaque, straight into the world pass as the
/// buildings are, and their shadows, a soft disc under each on the
/// ground, blended over it after the roads.
final class TreePipeline {
    let pipelineState: any GPURenderPipeline
    /// The shadow discs: a quad per instance from the vertex index, no
    /// vertex buffer, multiplied into the ground (the colour it writes is
    /// the darkening, `shadowColorMultiplier`).
    let shadowPipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        // The 20-byte vertex of the model file (`TreeModelContents`): the
        // position in metres, the normal as signed bytes with a padding
        // byte, the shading as four bytes.
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float3, offset: 0, bufferIndex: 0)
        layout.attributes[1] = GPUVertexAttribute(format: .char4Normalized, offset: 12, bufferIndex: 0)
        layout.attributes[2] = GPUVertexAttribute(format: .uchar4Normalized, offset: 16, bufferIndex: 0)
        layout.strides[0] = TreeModelContents.vertexStride

        var trees = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "treeVertexShader"),
                                                fragmentFunction: GPUShaderFunction(name: "treeFragmentShader"),
                                                colorTargets: [GPUColorTarget(format: pixelFormat)])
        trees.label = "Trees"
        trees.vertexLayout = layout
        trees.depthStencilFormat = .depth32FloatStencil8
        trees.sampleCount = sampleCount

        // Multiplied into the ground: the colour is the destination's
        // times the source's, the alpha the destination's.
        var shadowColor = GPUColorTarget(format: pixelFormat)
        shadowColor.blend = (color: GPUBlendComponent(source: .destinationColor, destination: .zero),
                             alpha: GPUBlendComponent(source: .zero, destination: .one))
        var shadows = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "treeShadowVertexShader"),
                                                  fragmentFunction: GPUShaderFunction(name: "treeShadowFragmentShader"),
                                                  colorTargets: [shadowColor])
        shadows.label = "TreeShadows"
        shadows.depthStencilFormat = .depth32FloatStencil8
        shadows.sampleCount = sampleCount
        do {
            pipelineState = try device.makeRenderPipeline(trees)
            shadowPipelineState = try device.makeRenderPipeline(shadows)
        } catch {
            fatalError("Failed to create the tree pipelines: \(error)")
        }
    }
}
