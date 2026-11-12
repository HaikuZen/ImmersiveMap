// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

final class RendererLabelDrawer {
    private init() {}

    // Cache of the encoder state actually bound. Metal argument slots live
    // at the encoder level and survive pipeline state changes, so re-setting
    // the same value into the same slot can be skipped: for labels almost all
    // style runs of a batch share the font texture and label shift, and without the cache
    // GPU Frame Capture flagged dozens of such calls as redundant binding.
    private struct EncoderBindings {
        var isPoiPipelineBound = false
        var fragmentTexture: ObjectIdentifier?
        var vertexBuffer0: ObjectIdentifier?
        var vertexBuffer0Offset: Int?
        var labelShift: simd_int1?
        var textStyle: TextStyleUniform?
        var poiIconStyle: PoiIconStyleUniform?
        var routeShieldStyle: RouteShieldStyleUniform?
    }

    /// `handover` is how far the globe's look has been handed over to the
    /// plane's (`FrameContext.groundHandover`): a label's colours on the
    /// globe (`LabelTextStyle.sphereFillColor`) at 0, its own at 1.
    /// `labelOpacity` is the frame's factor over every label's own
    /// opacity (`FrameContextServices.labelOpacity`), the POIs' for a POI's
    /// plate and name.
    static func drawBaseLabels(renderEncoder: any GPURenderEncoder,
                               screenMatrix: matrix_float4x4,
                               screenScale: ScreenScale,
                               textRenderer: TextRenderer,
                               poiSpriteTexture: any GPUTexture,
                               screenPositionsBuffer: any GPUBuffer,
                               labelRuntimeMetaBuffer: any GPUBuffer,
                               baseLabelsDrawBatches: [BaseLabelDrawBatch],
                               handover: Float = 1,
                               labelOpacity: LabelOpacityFrame = .solid) {
        // Label geometry is authored in layout points; this is the one place the
        // base label pass converts it to the device pixels the screen matrix maps.
        let pixelsPerPoint = screenScale.pixelsPerPoint

        renderEncoder.setVertexValue(screenMatrix, index: 1)
        renderEncoder.setVertexBuffer(screenPositionsBuffer, offset: 0, index: 2)
        renderEncoder.setVertexValue(pixelsPerPoint, index: 7)
        renderEncoder.setVertexBuffer(labelRuntimeMetaBuffer, offset: 0, index: 6)

        var bindings = EncoderBindings()

        for drawBatch in baseLabelsDrawBatches {
            for poiIconRun in drawBatch.poiIconRuns {
                guard let poiIconVertices = poiIconRun.localVertices,
                      poiIconRun.localVertexCount > 0 else {
                    continue
                }

                if bindings.isPoiPipelineBound == false {
                    renderEncoder.setPipeline(textRenderer.poiIconPipelineState)
                    setFragmentTexture(poiSpriteTexture, renderEncoder: renderEncoder, bindings: &bindings)
                    bindings.isPoiPipelineBound = true
                }
                let iconStyle = PoiIconStyleUniform(
                    backgroundColor: SIMD4<Float>(poiIconRun.style.fillColor.x,
                                                  poiIconRun.style.fillColor.y,
                                                  poiIconRun.style.fillColor.z,
                                                  1.0),
                    iconColor: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
                    opacity: labelOpacity.opacity(of: poiIconRun.style)
                )
                if bindings.poiIconStyle != iconStyle {
                    renderEncoder.setFragmentValue(iconStyle, index: 0)
                    bindings.poiIconStyle = iconStyle
                }
                setVertexBuffer0(poiIconVertices, renderEncoder: renderEncoder, bindings: &bindings)
                setLabelShift(simd_int1(drawBatch.globalLabelStart), renderEncoder: renderEncoder, bindings: &bindings)
                renderEncoder.draw(.triangle, vertexStart: 0, vertexCount: poiIconRun.localVertexCount)
            }
        }

        drawRouteShieldPlates(renderEncoder: renderEncoder,
                              textRenderer: textRenderer,
                              baseLabelsDrawBatches: baseLabelsDrawBatches,
                              bindings: &bindings)

        renderEncoder.setPipeline(textRenderer.labelPipelineState)
        drawBaseLabelText(renderEncoder: renderEncoder,
                          screenScale: screenScale,
                          textRenderer: textRenderer,
                          baseLabelsDrawBatches: baseLabelsDrawBatches,
                          handover: handover,
                          labelOpacity: labelOpacity,
                          bindings: &bindings)
    }

    /// `sceneDepth` is the world's depth the buildings paint over the road
    /// names with, and `sceneDepthUniforms` says whether it is read at all
    /// (`RoadLabelDrawSubsystem`); a texture is bound either way.
    static func drawRoadLabels(renderEncoder: any GPURenderEncoder,
                               screenMatrix: matrix_float4x4,
                               screenScale: ScreenScale,
                               textRenderer: TextRenderer,
                               roadDrawLabels: [DrawRoadLabels],
                               sceneDepth: any GPUTexture,
                               sceneDepthUniforms: RoadLabelSceneDepthUniforms,
                               labelOpacity: LabelOpacityFrame = .solid) {
        guard roadDrawLabels.isEmpty == false else {
            return
        }

        renderEncoder.setPipeline(textRenderer.roadLabelPipelineState)
        renderEncoder.setVertexValue(sceneDepthUniforms, index: 8)
        renderEncoder.setFragmentValue(sceneDepthUniforms, index: 1)
        renderEncoder.setFragmentTexture(sceneDepth, index: 1)
        renderEncoder.setVertexValue(screenMatrix, index: 1)
        // Identical for all road labels - bound once per pass.
        let glyphShift: simd_int1 = 0
        renderEncoder.setVertexValue(glyphShift, index: 5)
        let screenOffset = SIMD2<Float>(repeating: 0.0)
        renderEncoder.setVertexValue(screenOffset, index: 6)
        let pixelsPerPoint = screenScale.pixelsPerPoint
        renderEncoder.setVertexValue(pixelsPerPoint, index: 7)

        var bindings = EncoderBindings()
        for drawLabel in roadDrawLabels {
            guard drawLabel.localGlyphVertexCount > 0 else {
                continue
            }

            renderEncoder.setVertexBuffer(drawLabel.placementBuffer, offset: 0, index: 2)
            renderEncoder.setVertexBuffer(drawLabel.glyphInputBuffer, offset: 0, index: 3)
            renderEncoder.setVertexBuffer(drawLabel.runtimeMetaBuffer, offset: 0, index: 4)
            setVertexBuffer0(drawLabel.localGlyphVertices, renderEncoder: renderEncoder, bindings: &bindings)

            let style = drawLabel.labelStyle
            let texture = style.weight == .bold ? textRenderer.texture : textRenderer.thinTexture
            setFragmentTexture(texture, renderEncoder: renderEncoder, bindings: &bindings)

            // One draw: the fragment stage resolves the fill and the halo
            // from the two distance fields at once (shadeGlyph), so nothing
            // is gained by an outline pass under a fill pass except twice the
            // fragments.
            let textStyle = TextStyleUniform(textColor: style.fillColor,
                                             strokeColor: style.strokeColor,
                                             strokeWidthPx: style.haloWidthPixels(screenScale: screenScale),
                                             fillBiasPx: style.emboldenPixels(screenScale: screenScale),
                                             opacity: labelOpacity.opacity(of: style),
                                             haloSoftness: style.haloSoftness)
            setTextStyle(textStyle, renderEncoder: renderEncoder, bindings: &bindings)
            renderEncoder.draw(.triangle, vertexStart: 0, vertexCount: drawLabel.localGlyphVertexCount)
        }
    }

    /// The plates of the route signs, one draw per plate run, over the POI
    /// discs and under every label's text: a sign's number is a glyph run
    /// of its own and draws over its plate with the rest of the text.
    private static func drawRouteShieldPlates(renderEncoder: any GPURenderEncoder,
                                              textRenderer: TextRenderer,
                                              baseLabelsDrawBatches: [BaseLabelDrawBatch],
                                              bindings: inout EncoderBindings) {
        var isPipelineBound = false
        for drawBatch in baseLabelsDrawBatches {
            for run in drawBatch.routeShieldRuns {
                guard let vertices = run.localVertices, run.localVertexCount > 0 else {
                    continue
                }
                if isPipelineBound == false {
                    renderEncoder.setPipeline(textRenderer.routeShieldPipelineState)
                    isPipelineBound = true
                }
                let style = RouteShieldStyleUniform(run.style)
                if bindings.routeShieldStyle != style {
                    renderEncoder.setFragmentValue(style, index: 0)
                    bindings.routeShieldStyle = style
                    // The slot is shared with the other fragment uniforms.
                    bindings.poiIconStyle = nil
                    bindings.textStyle = nil
                }
                setVertexBuffer0(vertices, renderEncoder: renderEncoder, bindings: &bindings)
                setLabelShift(simd_int1(drawBatch.globalLabelStart), renderEncoder: renderEncoder, bindings: &bindings)
                renderEncoder.draw(.triangle, vertexStart: 0, vertexCount: run.localVertexCount)
            }
        }
    }

    /// The base label text, one draw per style run: the fragment stage
    /// shades the fill and the halo together from the two distance fields
    /// (shadeGlyph), so the former outline pass under a fill pass only
    /// doubled the fragments. Where two labels touch, the later one's halo
    /// now covers the earlier one's fill, which the collision pass keeps
    /// rare and the halo width keeps small.
    private static func drawBaseLabelText(renderEncoder: any GPURenderEncoder,
                                          screenScale: ScreenScale,
                                          textRenderer: TextRenderer,
                                          baseLabelsDrawBatches: [BaseLabelDrawBatch],
                                          handover: Float,
                                          labelOpacity: LabelOpacityFrame,
                                          bindings: inout EncoderBindings) {
        for drawBatch in baseLabelsDrawBatches {
            for run in drawBatch.labelsByStyleRuns {
                guard let localGlyphVertices = run.localGlyphVertices,
                      run.localGlyphVertexCount > 0 else {
                    continue
                }

                let style = run.style
                let texture = style.weight == .bold ? textRenderer.texture : textRenderer.thinTexture
                // The colours are the globe's look of the label handed over
                // to the plane's with the air.
                let textStyle = TextStyleUniform(textColor: style.fillColor(atHandover: handover),
                                                 strokeColor: style.strokeColor(atHandover: handover),
                                                 strokeWidthPx: style.haloWidthPixels(screenScale: screenScale),
                                                 fillBiasPx: style.emboldenPixels(screenScale: screenScale),
                                                 opacity: labelOpacity.opacity(of: style),
                                                 haloSoftness: style.haloSoftness)

                setFragmentTexture(texture, renderEncoder: renderEncoder, bindings: &bindings)
                setTextStyle(textStyle, renderEncoder: renderEncoder, bindings: &bindings)
                setVertexBuffer0(localGlyphVertices, renderEncoder: renderEncoder, bindings: &bindings)
                setLabelShift(simd_int1(drawBatch.globalLabelStart), renderEncoder: renderEncoder, bindings: &bindings)
                renderEncoder.draw(.triangle, vertexStart: 0, vertexCount: run.localGlyphVertexCount)
            }
        }
    }

    private static func setFragmentTexture(_ texture: (any GPUTexture)?,
                                           renderEncoder: any GPURenderEncoder,
                                           bindings: inout EncoderBindings) {
        guard let texture else { return }
        let identity = ObjectIdentifier(texture)
        guard bindings.fragmentTexture != identity else { return }
        renderEncoder.setFragmentTexture(texture, index: 0)
        bindings.fragmentTexture = identity
    }

    private static func setVertexBuffer0(_ view: TileBufferView,
                                         renderEncoder: any GPURenderEncoder,
                                         bindings: inout EncoderBindings) {
        // Views of different tiles share one backing buffer per tile, so the
        // dedup key is (buffer, offset), not the buffer alone.
        let identity = ObjectIdentifier(view.gpuBuffer)
        guard bindings.vertexBuffer0 != identity || bindings.vertexBuffer0Offset != view.offset else { return }
        renderEncoder.setVertexBuffer(view.gpuBuffer, offset: view.offset, index: 0)
        bindings.vertexBuffer0 = identity
        bindings.vertexBuffer0Offset = view.offset
    }

    private static func setLabelShift(_ shift: simd_int1,
                                      renderEncoder: any GPURenderEncoder,
                                      bindings: inout EncoderBindings) {
        guard bindings.labelShift != shift else { return }
        renderEncoder.setVertexValue(shift, index: 3)
        bindings.labelShift = shift
    }

    private static func setTextStyle(_ textStyle: TextStyleUniform,
                                     renderEncoder: any GPURenderEncoder,
                                     bindings: inout EncoderBindings) {
        guard bindings.textStyle != textStyle else { return }
        renderEncoder.setFragmentValue(textStyle, index: 0)
        bindings.textStyle = textStyle
    }
}
