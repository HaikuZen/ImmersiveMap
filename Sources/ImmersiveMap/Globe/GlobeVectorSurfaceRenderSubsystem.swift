// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The globe's ground: the placements' ground geometry projected onto the
/// sphere in the vertex stage (`GlobeVectorSurfaceDrawer`). A tile's extent
/// is its full square: which source owns a pixel is the planner's
/// decision, marked by the placement prepass in the tile-priority
/// stencil and tested by every pass, and the far hemisphere goes to
/// back-face culling. Every source draws in one call, and a coarser
/// source's overflow stays out of the ground given to a finer tile.
final class GlobeVectorSurfaceRenderSubsystem: RenderSubsystem {
    let name: String = "GlobeVectorSurface"

    private let pipeline: TilePipeline
    private let depthDisabledState: any GPUDepthStencilState
    private let opaqueDepthState: any GPUDepthStencilState
    private let ribbonOwnerDepthState: any GPUDepthStencilState
    private let translucentDepthState: any GPUDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState

    init(pipeline: TilePipeline,
         depthDisabledState: any GPUDepthStencilState,
         opaqueDepthState: any GPUDepthStencilState,
         ribbonOwnerDepthState: any GPUDepthStencilState,
         translucentDepthState: any GPUDepthStencilState,
         debugOverlayControls: DebugOverlayControlState) {
        self.pipeline = pipeline
        self.depthDisabledState = depthDisabledState
        self.opaqueDepthState = opaqueDepthState
        self.ribbonOwnerDepthState = ribbonOwnerDepthState
        self.translucentDepthState = translucentDepthState
        self.debugOverlayControls = debugOverlayControls
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: any GPURenderEncoder, frameContext: FrameContext) {
        guard layer == .globeVectorSurface,
              frameContext.renderSurfaceMode == .spherical else {
            return
        }
        let placeTilesContext = frameContext.sharedState.tilePlacementState.placeTilesContext
        guard placeTilesContext.tilePlacements.isEmpty == false else { return }
        let globe = frameContext.globeRenderUniform
        let pureSphere = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                            transition: globe.transition)
        let globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: frameContext.cameraUniform.matrix)
        let isWireframeEnabled = debugOverlayControls.snapshot().wireframeEnabled
        encoder.setDepthStencilState(depthDisabledState)
        GlobeVectorSurfaceDrawer.draw(renderEncoder: encoder,
                                      cameraUniform: frameContext.cameraUniform,
                                      globe: globe,
                                      cameraZoom: frameContext.planningZoom,
                                      pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                      drawableHeightPx: Float(frameContext.drawSize.height),
                                      renderMapSize: frameContext.resolvedPresentation.renderNormalizationState.flatRenderMapSize,
                                      placeTilesContext: placeTilesContext,
                                      pipeline: pipeline,
                                      opaqueDepthState: opaqueDepthState,
                                      ribbonOwnerDepthState: ribbonOwnerDepthState,
                                      translucentDepthState: translucentDepthState,
                                      depthDisabledState: depthDisabledState,
                                      isWireframeEnabled: isWireframeEnabled,
                                      pureSphere: pureSphere,
                                      globeFrame: globeFrame,
                                      globeLight: GlobeLightUniform.resolve(frameContext: frameContext),
                                      handoverUniform: TileSphereHandoverUniform.make(
                                          transition: globe.transition,
                                          presentation: frameContext.services.settings.presentation))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
