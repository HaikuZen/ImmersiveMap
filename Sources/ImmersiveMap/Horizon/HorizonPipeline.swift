// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The pass that paints the air around the surface's edge: the globe's
/// atmosphere and limb feather, the flat map's fog. One shading function
/// behind a side constant, two depth tests around it (see
/// `HorizonRenderSubsystem`), one geometry: the band (`HorizonBandMesh`).
final class HorizonPipeline {
    let skyPipelineState: any GPURenderPipeline
    let groundPipelineState: any GPURenderPipeline
    let bandMesh: HorizonBandMesh

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        // Mirrors HorizonBandMesh.Vertex: two floats.
        var bandLayout = GPUVertexLayout()
        bandLayout.attributes[0] = GPUVertexAttribute(format: .float, offset: 0, bufferIndex: 0)
        bandLayout.attributes[1] = GPUVertexAttribute(format: .float,
                                                      offset: MemoryLayout<Float>.stride,
                                                      bufferIndex: 0)
        bandLayout.strides[0] = MemoryLayout<HorizonBandMesh.Vertex>.stride
        // Premultiplied "over": the shader hands out the tint already
        // weighted by its coverage, and the coverage in alpha, so the
        // haze covers the edge and thins to nothing away from it. Alpha
        // composes the same way, which keeps the frame's own coverage
        // right where space is transparent.
        var color = GPUColorTarget(format: pixelFormat)
        color.blend = (color: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha),
                       alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        func makeState(groundSide: Bool) -> any GPURenderPipeline {
            // Function constant 0 picks the side the fragment shades.
            let fragment = GPUShaderFunction(name: "horizonBandFragmentShader",
                                             constants: [0: .bool(groundSide)])
            var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "horizonBandVertexShader"),
                                                         fragmentFunction: fragment,
                                                         colorTargets: [color])
            descriptor.label = groundSide ? "HorizonGroundPipeline" : "HorizonSkyPipeline"
            descriptor.vertexLayout = bandLayout
            descriptor.depthStencilFormat = .depth32FloatStencil8
            descriptor.sampleCount = sampleCount
            do {
                return try device.makeRenderPipeline(descriptor)
            } catch {
                fatalError("Failed to create the horizon pipeline: \(error)")
            }
        }
        skyPipelineState = makeState(groundSide: false)
        groundPipelineState = makeState(groundSide: true)
        guard let bandMesh = HorizonBandMesh(device: device) else {
            fatalError("Failed to allocate the horizon band mesh")
        }
        self.bandMesh = bandMesh
    }

    func pipelineState(groundSide: Bool) -> any GPURenderPipeline {
        groundSide ? groundPipelineState : skyPipelineState
    }
}

/// Draws one side of the horizon layer: the band at the far plane, whose
/// vertices are directions and whose fragments resolve the angle above or
/// below the edge from them. Stateless beyond the pipeline; every frame's
/// parameters arrive as one uniform.
final class HorizonRenderer {
    private let pipeline: HorizonPipeline

    init(pipeline: HorizonPipeline) {
        self.pipeline = pipeline
    }

    func draw(renderEncoder: any GPURenderEncoder,
              uniform: HorizonUniform,
              groundSide: Bool) {
        renderEncoder.setPipeline(pipeline.pipelineState(groundSide: groundSide))
        renderEncoder.setCullMode(.none)
        renderEncoder.setFragmentValue(uniform, index: 0)
        let mesh = pipeline.bandMesh
        renderEncoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexValue(uniform, index: 1)
        renderEncoder.drawIndexed(.triangle,
                                  indexCount: mesh.indexCount,
                                  indexType: .uint16,
                                  indexBuffer: mesh.indexBuffer,
                                  indexBufferOffset: 0,
                                  instanceCount: 1,
                                  baseVertex: 0,
                                  baseInstance: 0)
    }
}
