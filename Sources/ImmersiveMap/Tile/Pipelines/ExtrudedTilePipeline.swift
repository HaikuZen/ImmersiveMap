// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

final class ExtrudedTilePipeline {
    let pipelineState: any GPURenderPipeline
    let shadowPipelineState: any GPURenderPipeline
    let reliefPipelineState: any GPURenderPipeline
    let reliefShadowPipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        // Function constant 0 lifts the buildings by the relief.
        func function(_ name: String, relief: Bool) -> GPUShaderFunction {
            GPUShaderFunction(name: name, constants: [0: .bool(relief)])
        }

        // The 12-byte layout of ExtrudedVertexIn: quantized positions fed
        // as raw Int16 triples (the fetch converts integer formats to float
        // with the numeric value; the shader applies the inverse fixed-point
        // scale), normals as char3Normalized, the style index, and two
        // bytes of padding to the stride Metal requires.
        assert(MemoryLayout<ExtrudedVertexIn>.stride == 12,
               "The vertex layout mirrors ExtrudedVertexIn byte for byte")
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .short3, offset: 0, bufferIndex: 0)
        layout.attributes[1] = GPUVertexAttribute(format: .char3Normalized, offset: 6, bufferIndex: 0)
        layout.attributes[2] = GPUVertexAttribute(format: .uchar, offset: 9, bufferIndex: 0)
        layout.attributes[3] = GPUVertexAttribute(format: .ushort, offset: 10, bufferIndex: 0)
        layout.strides[0] = MemoryLayout<ExtrudedVertexIn>.stride

        func buildings(relief: Bool) -> GPURenderPipelineDescriptor {
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: function("tileExtrudedVertexShader", relief: relief),
                                                         fragmentFunction: GPUShaderFunction(name: "tileExtrudedFragmentShader"),
                                                         colorTargets: [GPUColorTarget(format: pixelFormat)])
            descriptor.label = relief ? "ExtrudedTilesRelief" : "ExtrudedTiles"
            descriptor.vertexLayout = layout
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            return descriptor
        }
        // The caster pass writes a plain 2D depth attachment, one shadow
        // window: no colour, no fragment function, one sample.
        func casters(relief: Bool) -> GPURenderPipelineDescriptor {
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: function("tileExtrudedShadowVertexShader", relief: relief),
                                                         fragmentFunction: nil,
                                                         colorTargets: [])
            descriptor.label = relief ? "ExtrudedTileCastersRelief" : "ExtrudedTileCasters"
            descriptor.vertexLayout = layout
            descriptor.depthStencilFormat = ShadowCascadeAtlas.depthFormat
            descriptor.sampleCount = 1
            return descriptor
        }
        do {
            pipelineState = try device.makeRenderPipeline(buildings(relief: false))
            shadowPipelineState = try device.makeRenderPipeline(casters(relief: false))
            reliefPipelineState = try device.makeRenderPipeline(buildings(relief: true))
            reliefShadowPipelineState = try device.makeRenderPipeline(casters(relief: true))
        } catch {
            fatalError("Failed to create the building pipelines: \(error)")
        }
    }

    func selectPipeline(renderEncoder: any GPURenderEncoder, relief: Bool = false) {
        renderEncoder.setPipeline(relief ? reliefPipelineState : pipelineState)
    }

    func selectShadowPipeline(renderEncoder: any GPURenderEncoder, relief: Bool = false) {
        renderEncoder.setPipeline(relief ? reliefShadowPipelineState : shadowPipelineState)
    }
}
