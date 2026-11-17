// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RoadLabelDrawSubsystem.swift
//  ImmersiveMap
//

import ImmersiveMapGPU
import PortableFoundation
import simd

/// Draws the road names in the overlay pass. From
/// `RoadSettings.hidesBehindBuildingsFromZoom` on the flat map, the buildings
/// and the models paint over them: the world pass keeps its depth for the
/// frame (`FrameContextSharedState.sceneDepthForLabelsRequested`), and the
/// glyph fragments behind a building are dropped, pixel by pixel. Nothing
/// else about the names changes: they keep their place in the collisions
/// and their fades.
final class RoadLabelDrawSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "RoadLabelDraw"

    private let textRenderer: TextRenderer
    private let labelDepthState: any GPUDepthStencilState
    private let depthDisabledState: any GPUDepthStencilState
    /// Bound where the frame keeps no world depth: a depth texture of 1.0,
    /// which nothing is behind.
    private let fallbackDepthTexture: any GPUTexture
    private let hidesBehindBuildingsFromZoom: Float

    private(set) var hasRenderableLabels: Bool = false

    init(textRenderer: TextRenderer,
         labelDepthState: any GPUDepthStencilState,
         depthDisabledState: any GPUDepthStencilState,
         fallbackDepthTexture: any GPUTexture,
         hidesBehindBuildingsFromZoom: Float) {
        self.textRenderer = textRenderer
        self.labelDepthState = labelDepthState
        self.depthDisabledState = depthDisabledState
        self.fallbackDepthTexture = fallbackDepthTexture
        self.hidesBehindBuildingsFromZoom = hidesBehindBuildingsFromZoom
    }

    func update(frameContext: FrameContext) {
        hasRenderableLabels = frameContext.sharedState.roadLabelState.drawLabels.isEmpty == false
        if hasRenderableLabels, Self.paintsOverNames(frameContext: frameContext,
                                                     fromZoom: hidesBehindBuildingsFromZoom) {
            frameContext.sharedState.sceneDepthForLabelsRequested = true
        }
    }

    /// Whether the buildings paint over the road names this frame: on the
    /// flat map, where the names and the buildings are, from the zoom.
    static func paintsOverNames(frameContext: FrameContext, fromZoom zoom: Float) -> Bool {
        frameContext.renderSurfaceMode == .flat
            && frameContext.screenSpaceProjectionMode == .flat
            && Float(frameContext.planningZoom) >= zoom
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.labelsEnabled = builder.labelsEnabled || hasRenderableLabels
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry) {
        if let runtimeMetaBuffer = frameContext.sharedState.roadLabelState.runtimeMetaBuffer {
            resourceRegistry.setBuffer(runtimeMetaBuffer, named: .roadLabelRuntimeBuffer)
        }
    }

    func encode(layer: RenderLayer, encoder: any GPURenderEncoder, frameContext: FrameContext) {
        guard layer == .labels else {
            return
        }

        let roadLabelState = frameContext.sharedState.roadLabelState
        guard roadLabelState.instanceCount > 0,
              roadLabelState.glyphCount > 0,
              roadLabelState.drawLabels.isEmpty == false else {
            return
        }

        // Same depth as BaseLabelDrawSubsystem: the overlay pass's own
        // depth orders halo under fill.
        encoder.setDepthStencilState(labelDepthState)
        let sceneDepth = frameContext.sharedState.gpuSceneDepthTexture
        // The eye ray through a pixel comes from the CPU's matrix, whose
        // inverse unprojects. The anchor's depth is compared with the
        // scene depth the GPU wrote, so it is projected with the uniform's
        // matrix, whose z is the GPU's (RenderCamera.gpuClipDepthAdjustment):
        // the roads lie under it there, the walls over it.
        let sceneDepthUniforms = RoadLabelSceneDepthUniforms(
            projectionView: frameContext.cameraUniform.matrix,
            inverseProjectionView: frameContext.cameraMatrices.projectionView.inverse,
            eye: frameContext.cameraEye,
            viewportSize: SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height)),
            enabled: sceneDepth == nil ? 0 : 1)
        let depth = sceneDepth ?? fallbackDepthTexture
        RendererLabelDrawer.drawRoadLabels(renderEncoder: encoder,
                                           screenMatrix: frameContext.cameraMatrices.screen,
                                           screenScale: frameContext.screenScale,
                                           textRenderer: textRenderer,
                                           roadDrawLabels: roadLabelState.drawLabels,
                                           // The world pass's depth, or the fallback in the
                                           // shadow map's format.
                                           sceneDepth: depth,
                                           sceneDepthUniforms: sceneDepthUniforms,
                                           labelOpacity: frameContext.services.labelOpacity)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
