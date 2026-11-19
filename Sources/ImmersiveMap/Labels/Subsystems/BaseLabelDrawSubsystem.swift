// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  BaseLabelDrawSubsystem.swift
//  ImmersiveMap
//

import ImmersiveMapGPU
import PortableFoundation

final class BaseLabelDrawSubsystem: RenderSubsystem, RenderPassAvailabilityProvider {
    let name: String = "BaseLabelDraw"

    private let textRenderer: TextRenderer
    /// The POI icons' atlas texture (`PoiSpriteAtlas`, drawn on Apple's
    /// platforms).
    private let poiSpriteTexture: any GPUTexture
    private let labelDepthState: any GPUDepthStencilState
    private let depthDisabledState: any GPUDepthStencilState

    private(set) var hasRenderableLabels: Bool = false

    init(textRenderer: TextRenderer,
         poiSpriteTexture: any GPUTexture,
         labelDepthState: any GPUDepthStencilState,
         depthDisabledState: any GPUDepthStencilState) {
        self.textRenderer = textRenderer
        self.poiSpriteTexture = poiSpriteTexture
        self.labelDepthState = labelDepthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext: FrameContext) {
        hasRenderableLabels = frameContext.sharedState.baseLabelState.labelInputsCount > 0
    }

    func contributePassAvailability(settings _: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder) {
        builder.labelsEnabled = builder.labelsEnabled || hasRenderableLabels
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry: RenderResourceRegistry) {
        if let labelRuntimeMetaBuffer = frameContext.sharedState.baseLabelState.labelRuntimeMetaBuffer {
            resourceRegistry.setBuffer(labelRuntimeMetaBuffer, named: .baseLabelRuntimeBuffer)
        }
    }

    func encode(layer: RenderLayer, encoder: any GPURenderEncoder, frameContext: FrameContext) {
        guard layer == .labels else {
            return
        }

        let baseLabelState = frameContext.sharedState.baseLabelState
        guard baseLabelState.labelInputsCount > 0 else {
            return
        }

        guard let labelRuntimeMetaBuffer = baseLabelState.labelRuntimeMetaBuffer else {
            return
        }

        guard let screenPositionsBuffer = baseLabelState.screenPositionsBuffer else {
            return
        }

        // The labels always draw in the overlay pass over its own cleared
        // depth: they rasterize at the far plane (see LabelTextVertex.metal)
        // and write fill and halo depths just short of it, so the halo of a
        // later glyph never covers the fill of an earlier one
        // (TextShader.metal). Nothing else writes that depth, so the scene
        // models, drawn in the world pass, never hide a label.
        encoder.setDepthStencilState(labelDepthState)
        RendererLabelDrawer.drawBaseLabels(renderEncoder: encoder,
                                           screenMatrix: frameContext.cameraMatrices.screen,
                                           screenScale: frameContext.screenScale,
                                           textRenderer: textRenderer,
                                           poiSpriteTexture: poiSpriteTexture,
                                           screenPositionsBuffer: screenPositionsBuffer,
                                           labelRuntimeMetaBuffer: labelRuntimeMetaBuffer,
                                           baseLabelsDrawBatches: baseLabelState.baseLabelsDrawBatches,
                                           handover: frameContext.groundHandover,
                                           labelOpacity: frameContext.services.labelOpacity)
        encoder.setDepthStencilState(depthDisabledState)
    }

    func handleMemoryWarning() {}

    func evict() {}
}
