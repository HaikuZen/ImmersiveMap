// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

/// The ground relief's shadow casters in the frame: the drawing
/// (`GroundReliefShadowCasterDrawing`, where the casters are explained),
/// on the plane, in a caster layer of a cascade the light reaches, when the
/// mountains cast this frame.
final class GroundReliefShadowCasterSubsystem: RenderSubsystem {
    let name: String = "GroundReliefShadowCasters"

    private let drawing: GroundReliefShadowCasterDrawing

    /// `device` makes the grids (`RasterTileGrid`), on the GPU interface.
    init(device: any GPUDevice,
         pipeline: RasterTilePipeline,
         depthState: any GPUDepthStencilState,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings) {
        drawing = GroundReliefShadowCasterDrawing(pipeline: pipeline,
                                                  grid: RasterTileGrid(device: device),
                                                  depthState: depthState,
                                                  groundFlattening: groundFlattening)
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard let slot = ShadowCascadeSlot(casterLayer: layer),
              frameContext.renderSurfaceMode == .flat,
              let relief = frameContext.services.groundRelief, relief.castsShadows,
              let lightProjectionView = frameContext.shadowFrameState?.lightProjectionView(for: slot) else { return }
        drawing.encode(placements: frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements,
                       relief: relief,
                       lightProjectionView: lightProjectionView,
                       flatRenderState: frameContext.resolvedPresentation.flatRenderState,
                       encoder: MetalRenderEncoder(encoder))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
