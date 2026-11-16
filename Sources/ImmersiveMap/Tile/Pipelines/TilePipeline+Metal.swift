// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

/// The sphere's pipeline selections on Metal's encoder, for the globe's
/// ground drawer still on Metal (`GlobeVectorSurfaceDrawer`). They go when
/// it moves.
extension TilePipeline {
    func selectSphereOpaqueFillsPipeline(renderEncoder: MTLRenderCommandEncoder, morph: Bool) {
        renderEncoder.setRenderPipelineState(sphereOpaqueFillsPipeline(morph: morph).metalPipeline)
    }

    func selectSphereClassPipeline(renderEncoder: MTLRenderCommandEncoder,
                                   linesClass: Bool,
                                   morph: Bool,
                                   ribbonPhase: SphereRibbonPhase = .whole) {
        renderEncoder.setRenderPipelineState(sphereClassPipeline(linesClass: linesClass, morph: morph,
                                                                 ribbonPhase: ribbonPhase).metalPipeline)
    }
}
