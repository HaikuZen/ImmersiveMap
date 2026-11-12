// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The ground shadow mask's draw, apart from the subsystem that gates it
/// (`GroundShadowMaskRenderSubsystem`), so it builds and is tested
/// everywhere.
enum GroundShadowMaskDrawing {
    /// The mask's one draw: a fullscreen triangle that reads the cascades
    /// once per mask pixel. Internal so tests can record it.
    static func encodeMask(encoder: any GPURenderEncoder,
                           pipeline: GroundShadowMaskPipeline,
                           depthDisabledState: any GPUDepthStencilState,
                           maskUniform: GroundShadowMaskUniform,
                           shadowUniform: ShadowUniform,
                           shadowMap: any GPUTexture) {
        pipeline.select(renderEncoder: encoder)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.setCullMode(.none)
        encoder.setFragmentValue(maskUniform, index: 0)
        encoder.setFragmentValue(shadowUniform, index: 1)
        encoder.setFragmentTexture(shadowMap, index: 0)
        encoder.draw(.triangle, vertexStart: 0, vertexCount: 3)
    }
}
