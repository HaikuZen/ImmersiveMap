// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The debug overlay's coloured geometry (PolygonShader.metal): the axes'
/// lines, the tiles' outlines and the label bounds' frames as triangles,
/// and the plates under the overlay's text.
final class PolygonsPipeline {
    /// One vertex: a position the camera's or the screen's matrix places,
    /// and a colour with its alpha.
    struct Vertex {
        var position: SIMD4<Float>
        var color: SIMD4<Float>
    }

    let pipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        var layout = GPUVertexLayout()
        layout.attributes[0] = GPUVertexAttribute(format: .float4, offset: 0, bufferIndex: 0)
        layout.attributes[1] = GPUVertexAttribute(format: .float4, offset: MemoryLayout<SIMD4<Float>>.stride, bufferIndex: 0)
        layout.strides[0] = MemoryLayout<Vertex>.stride

        // The debug overlays this pipeline draws have always carried an alpha in
        // their color (the tile outline at 0.95, label bounds at 0.9), and the
        // blend makes those alphas mean what they say and lets an overlay lay a
        // readable plate under its own text, as the text pipeline blends. Alpha
        // blends with .one so coverage accumulates on a transparent destination;
        // over an opaque one the result is unchanged.
        var color = GPUColorTarget(format: pixelFormat)
        color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                       alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "polygonVertexShader"),
                                                     fragmentFunction: GPUShaderFunction(name: "polygonFragmentShader"),
                                                     colorTargets: [color])
        descriptor.label = "DebugPolygons"
        descriptor.vertexLayout = layout
        descriptor.depthStencilFormat = .depth32FloatStencil8
        descriptor.sampleCount = sampleCount
        do {
            pipelineState = try device.makeRenderPipeline(descriptor)
        } catch {
            fatalError("Could not create the debug overlay's pipeline: \(error)")
        }
    }

    func setPipelineState(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(pipelineState)
    }
}
