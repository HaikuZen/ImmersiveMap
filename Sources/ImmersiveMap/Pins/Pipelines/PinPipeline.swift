// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

// Every pin pipeline blends source-over with `.one` for the alpha channel, so
// coverage accumulates on a transparent destination (a pin hanging off the
// globe limb with transparent space). Over an opaque destination the result
// is unchanged. They read their instances from buffers, with no vertex
// layout, and draw in the overlay pass, which has the world pass's depth and
// stencil format.
enum PinPipelines {
    static func make(device: any GPUDevice,
                     pixelFormat: GPUPixelFormat,
                     sampleCount: Int,
                     vertexFunction: String,
                     fragmentFunction: String,
                     label: String) -> any GPURenderPipeline {
        var color = GPUColorTarget(format: pixelFormat)
        color.blend = (color: GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                       alpha: GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: vertexFunction),
                                                     fragmentFunction: GPUShaderFunction(name: fragmentFunction),
                                                     colorTargets: [color])
        descriptor.label = label
        descriptor.depthStencilFormat = .depth32FloatStencil8
        descriptor.sampleCount = sampleCount
        do {
            return try device.makeRenderPipeline(descriptor)
        } catch {
            fatalError("Could not create the \(label) pipeline: \(error)")
        }
    }
}

/// The pins' bodies (PinRender.metal, PinRender.wgsl).
final class PinPipeline {
    let pipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        pipelineState = PinPipelines.make(device: device,
                                          pixelFormat: pixelFormat,
                                          sampleCount: sampleCount,
                                          vertexFunction: "pinVertex",
                                          fragmentFunction: "pinFragment",
                                          label: "Pins")
    }

    func selectPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(pipelineState)
    }
}

/// The merged pins' counters (PinRender.metal, PinRender.wgsl).
final class PinCountBadgePipeline {
    let pipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        pipelineState = PinPipelines.make(device: device,
                                          pixelFormat: pixelFormat,
                                          sampleCount: sampleCount,
                                          vertexFunction: "pinCountBadgeVertex",
                                          fragmentFunction: "pinCountBadgeFragment",
                                          label: "PinCountBadges")
    }

    func selectPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(pipelineState)
    }
}
