// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// Pipeline for the beam cone from the geo point to the displaced circle
/// (PinBeam.metal, PinBeam.wgsl), drawn in the overlay pass before the pin
/// bubbles.
final class PinBeamPipeline {
    let beamPipelineState: any GPURenderPipeline

    init(device: any GPUDevice,
         pixelFormat: GPUPixelFormat,
         sampleCount: Int = 1) {
        beamPipelineState = PinPipelines.make(device: device,
                                              pixelFormat: pixelFormat,
                                              sampleCount: sampleCount,
                                              vertexFunction: "pinBeamVertex",
                                              fragmentFunction: "pinBeamFragment",
                                              label: "PinBeams")
    }

    func selectBeamPipeline(renderEncoder: any GPURenderEncoder) {
        renderEncoder.setPipeline(beamPipelineState)
    }
}
