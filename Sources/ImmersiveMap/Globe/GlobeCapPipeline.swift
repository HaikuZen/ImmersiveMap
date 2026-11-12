// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

final class GlobeCapPipeline {
    let pipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float2, offset: 0, bufferIndex: 0)
        layout.strides[0] = MemoryLayout<CapGeometry.Vertex>.stride

        var color = GPUColorTarget(format: pixelFormat)
        // Alpha blends with .one so coverage accumulates on a transparent
        // destination; over an opaque one the result is unchanged.
        color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                       alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))

        var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "globeCapVertexShader"),
                                                     fragmentFunction: GPUShaderFunction(name: "globeCapFragmentShader"),
                                                     colorTargets: [color])
        descriptor.label = "GlobeCap"
        descriptor.vertexLayout = layout
        descriptor.depthStencilFormat = .depth32FloatStencil8
        descriptor.sampleCount = sampleCount
        do {
            pipelineState = try device.makeRenderPipeline(descriptor)
        } catch {
            fatalError("Failed to create the globe cap pipeline: \(error)")
        }
    }

    func selectPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(pipelineState)
    }
}
