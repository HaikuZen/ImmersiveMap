// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import simd

/// The labels painted on the map (`LabelPlacement.surface`): drawn in the
/// world pass after the ground and its roads, on the flat map and on the globe
/// alike, through the ground's own projection. `update` picks the copy of
/// each label that draws (`SurfaceLabelSelection`), `encode` draws every
/// halo and then every fill. A label shows whole or not at all: nothing
/// fades in or out.
final class SurfaceLabelRenderSubsystem: RenderSubsystem {
    let name: String = "SurfaceLabels"

    private let pipeline: SurfaceLabelPipeline
    private let textRenderer: TextRenderer
    private let depthState: any GPUDepthStencilState
    private let depthDisabledState: any GPUDepthStencilState
    private var drawItems: [SurfaceLabelDrawing.Item] = []

    init(pipeline: SurfaceLabelPipeline,
         textRenderer: TextRenderer,
         depthState: any GPUDepthStencilState,
         depthDisabledState: any GPUDepthStencilState) {
        self.pipeline = pipeline
        self.textRenderer = textRenderer
        self.depthState = depthState
        self.depthDisabledState = depthDisabledState
    }

    func update(frameContext: FrameContext) {
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        // One source per tile and world copy. The sphere has one world, so
        // its placements' wrap is not part of a source there.
        let wrapsWorld = frameContext.renderSurfaceMode == .flat
        var seen = Set<FlatGroundSourceKey>()
        var sourceTiles: [(metalTile: MetalTile, worldWrap: Int8)] = []
        // A placement whose rules draw no labels offers none
        // (`TileDrawRules`).
        for placement in placements where placement.metalTile.tileBuffers.surfaceLabels.labels.isEmpty == false
            && placement.rules.drawsLabels {
            let worldWrap = wrapsWorld ? placement.placeIn.worldWrap : 0
            if seen.insert(FlatGroundSourceKey(tile: placement.metalTile.tile, worldWrap: worldWrap)).inserted {
                sourceTiles.append((placement.metalTile, worldWrap))
            }
        }
        let sources = sourceTiles.map {
            SurfaceLabelSelection.Source(labels: $0.metalTile.tileBuffers.surfaceLabels.labels,
                                         tileZoom: $0.metalTile.tile.z,
                                         worldWrap: $0.worldWrap)
        }
        let selected = SurfaceLabelSelection.select(sources: sources, cameraZoom: frameContext.planningZoom)
        drawItems = selected.compactMap { item in
            let source = sourceTiles[item.sourceIndex]
            guard let vertices = source.metalTile.tileBuffers.surfaceLabels.vertices else { return nil }
            return SurfaceLabelDrawing.Item(tile: source.metalTile.tile,
                                            worldWrap: source.worldWrap,
                                            record: sources[item.sourceIndex].labels[item.labelIndex],
                                            vertices: vertices)
        }
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .surfaceLabels, drawItems.isEmpty == false else { return }

        // Every tile at its own zoom has the same world size: the map's at
        // the frame's integer zoom over that zoom's tile count.
        let normalization = frameContext.resolvedPresentation.renderNormalizationState
        let viewportHeightPoints = Double(frameContext.drawSize.height) / max(Double(frameContext.pixelsPerPoint), 1)
        let tileScreenPoints = SurfaceLabelScale.tileScreenPoints(
            viewportHeightPoints: viewportHeightPoints,
            tileWorldSize: normalization.flatRenderMapSize / normalization.zoomScale
        )
        let surface: SurfaceLabelDrawing.Surface
        switch frameContext.renderSurfaceMode {
        case .flat:
            surface = .flat(frameContext.resolvedPresentation.flatRenderState)
        case .spherical:
            let globe = frameContext.globeRenderUniform
            surface = .sphere(globe: globe,
                              pureSphere: GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                                             transition: globe.transition),
                              handover: frameContext.groundHandover)
        }
        let frame = SurfaceLabelDrawing.Frame(
            cameraUniform: frameContext.cameraUniform,
            groundFog: GroundFogUniform.resolve(frameContext: frameContext),
            tileScreenPoints: tileScreenPoints,
            viewportSizePx: SIMD2<Float>(Float(frameContext.drawSize.width), Float(frameContext.drawSize.height)),
            pixelsPerPoint: Float(frameContext.pixelsPerPoint),
            labelOpacity: frameContext.services.labelOpacity,
            surface: surface
        )
        SurfaceLabelDrawing.draw(drawItems,
                                 frame: frame,
                                 pipeline: pipeline,
                                 textRenderer: textRenderer,
                                 depthState: depthState,
                                 depthDisabledState: depthDisabledState,
                                 encoder: MetalRenderEncoder(encoder))
    }

    func handleMemoryWarning() {}

    func evict() {
        drawItems = []
    }
}
