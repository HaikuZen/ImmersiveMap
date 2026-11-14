// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

/// The pipeline selections on Metal's encoder, for the ground drawers still
/// on Metal (`FlatMapSurfaceDrawer`, `GlobeVectorSurfaceDrawer`). They go
/// when the drawers move.
extension TilePipeline {
    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState.metalPipeline)
    }

    func selectFlatLinesPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(linesPipeline.metalPipeline)
    }

    @discardableResult
    func selectFlatRoadPipeline(renderEncoder: MTLRenderCommandEncoder, blended: Bool) -> Bool {
        guard let state = flatRoadPipeline(blended: blended) else { return false }
        renderEncoder.setRenderPipelineState(state.metalPipeline)
        return true
    }

    func selectFlatFillsPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(flatFillsPipeline.metalPipeline)
    }

    func selectFlatOpaquePipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(flatOpaquePipeline.metalPipeline)
    }

    @discardableResult
    func selectFlatReliefPipeline(_ flatClass: FlatClass, renderEncoder: MTLRenderCommandEncoder) -> Bool {
        guard let state = flatReliefPipeline(flatClass) else { return false }
        renderEncoder.setRenderPipelineState(state.metalPipeline)
        return true
    }

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
