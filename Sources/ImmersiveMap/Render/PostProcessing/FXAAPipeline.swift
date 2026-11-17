// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The FXAA pass (FXAA.metal): one triangle over the frame, sampling the
/// frame drawn before it and smoothing its edges.
final class FXAAPipeline {
    /// Mirror of `FXAAUniform` in FXAA.metal.
    struct Uniform {
        var inverseViewportSize: SIMD2<Float>
    }

    private let pipelineState: any GPURenderPipeline

    init(device: any GPUDevice, pixelFormat: GPUPixelFormat) {
        var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "postProcessingVertexShader"),
                                                     fragmentFunction: GPUShaderFunction(name: "fxaaFragmentShader"),
                                                     colorTargets: [GPUColorTarget(format: pixelFormat)])
        descriptor.label = "FXAA"
        do {
            pipelineState = try device.makeRenderPipeline(descriptor)
        } catch {
            fatalError("Failed to create the FXAA pipeline: \(error)")
        }
    }

    /// `width` and `height` are the frame's, in pixels.
    func draw(renderEncoder: any GPURenderEncoder,
              sourceTexture: any GPUTexture,
              width: Float,
              height: Float) {
        let uniform = Uniform(inverseViewportSize: SIMD2<Float>(1.0 / max(width, 1.0), 1.0 / max(height, 1.0)))
        renderEncoder.setPipeline(pipelineState)
        renderEncoder.setFragmentTexture(sourceTexture, index: 0)
        renderEncoder.setFragmentValue(uniform, index: 0)
        renderEncoder.draw(.triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: 0)
    }
}
