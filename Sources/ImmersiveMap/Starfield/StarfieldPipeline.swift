// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

final class StarfieldPipeline {
    private struct StarVertex {
        let position: SIMD3<Float>
        let size: Float
        let brightness: Float
        let temperature: Float
        let twinklePhase: Float
        let halo: Float
    }

    let starsPipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        let floatSize = MemoryLayout<Float>.stride
        let positionSize = MemoryLayout<SIMD3<Float>>.stride
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float3, offset: 0, bufferIndex: 0)
        for attribute in 1 ... 5 {
            layout.attributes[attribute] = GPUVertexAttribute(format: .float,
                                                              offset: positionSize + floatSize * (attribute - 1),
                                                              bufferIndex: 0)
        }
        layout.strides[0] = MemoryLayout<StarVertex>.stride

        var color = GPUColorTarget(format: pixelFormat)
        // Additive stars, with .one for the alpha channel: coverage accumulates
        // like the color instead of being squared by the source alpha.
        color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .one),
                       alpha: GPUBlendComponent(source: .one, destination: .one))

        var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "starfieldVertexShader"),
                                                     fragmentFunction: GPUShaderFunction(name: "starfieldFragmentShader"),
                                                     colorTargets: [color])
        descriptor.label = "Starfield"
        descriptor.vertexLayout = layout
        descriptor.depthStencilFormat = .depth32FloatStencil8
        descriptor.sampleCount = sampleCount
        descriptor.topology = .point

        do {
            starsPipelineState = try device.makeRenderPipeline(descriptor)
        } catch {
            fatalError("Failed to create starfield pipeline: \(error)")
        }
    }

    func selectStarsPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(starsPipelineState)
    }
}
