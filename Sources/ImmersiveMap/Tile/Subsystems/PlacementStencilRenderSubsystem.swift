// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import simd

/// The placement prepass, on either surface: before any ground draws, the
/// ground of every placement is marked in the tile-priority stencil with
/// the zoom of its source (`TileSourceStencilPriority`), the placements'
/// squares drawn coarse first so a finer placement's mark lies over a
/// coarser one's. The square is the placement's `placeIn`: the slot for
/// a tile in its own slot and for an ancestor standing in, the stand-in's
/// own square for a descendant. The ground passes then paint by
/// equality, each source the ground the planner gave it. The square is
/// the raster tile's grid (`RasterTileGrid`) through the raster tile's
/// vertex paths: on the plane raised by the relief like the ground is,
/// by the terrain of the slot's ring, so the marks lie where the ground
/// lies, and on the sphere projected as the ground is, resting or in the
/// morph.
///
/// On the relief the squares overlap on the screen as well as on the
/// ground: a near mountain stands in front of the ground of the squares
/// behind it, whatever their zoom, and the mark of a pixel has to be the
/// placement whose ground is seen there, which the order of the squares
/// cannot tell. So the relief takes two passes. The first draws the
/// ground's depth: every point of the ground once, from the placement the
/// planner gave it (`PlacementGroundSquare.squares(of:)`), each square on
/// its source's own grid lines, as its ground is drawn, so the surface is
/// the ground's and no two placements compete for one point of it. Then
/// the marks, every placement's whole square, coarse first as on the
/// plane, tested against that depth: a square's mark lands only where its
/// ground is the one in front, so the ground behind a mountain keeps the
/// mountain's mark, and a coarse square's mark inside a finer square lies
/// under the finer mark that follows it, however its coarser grid bulges
/// over the finer one, since the finer square's own surface is the depth
/// it is tested against. That depth serves the marks alone: once they are
/// written it is put back to the cleared far plane (one triangle over the
/// screen, `placementDepthResetVertexShader`), so the ground passes meet
/// the depth they always met, their own. The ground's own triangulation
/// of a grid cell is not the grid's two triangles, and on a cliff the two
/// surfaces part by the cell's twist, which no bias covers: tested
/// against the grid's depth, whole cells of the fills would drop out. A
/// coarse square's whole mark still covers the slivers along a finer
/// square's edge where the two grids part. The plane needs none of this:
/// its squares never share a pixel.
final class PlacementStencilRenderSubsystem: RenderSubsystem {
    let name: String = "PlacementStencil"

    private let drawing: PlacementStencilDrawing

    init(device: any GPUDevice,
         pipeline: PlacementStencilPipeline,
         placementStencilWriteState: any GPUDepthStencilState,
         placementDepthWriteState: any GPUDepthStencilState,
         placementStencilReliefWriteState: any GPUDepthStencilState,
         placementDepthResetState: any GPUDepthStencilState,
         depthDisabledState: any GPUDepthStencilState,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init()) {
        drawing = PlacementStencilDrawing(pipeline: pipeline,
                                          grid: RasterTileGrid(device: device),
                                          states: PlacementStencilDrawing.States(stencilWrite: placementStencilWriteState,
                                                                                 depthWrite: placementDepthWriteState,
                                                                                 stencilReliefWrite: placementStencilReliefWriteState,
                                                                                 depthReset: placementDepthResetState,
                                                                                 depthDisabled: depthDisabledState),
                                          groundFlattening: groundFlattening)
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard layer == .placementStencil else { return }
        let surface: PlacementStencilDrawing.Surface
        switch frameContext.renderSurfaceMode {
        case .flat:
            surface = .flat(frameContext.resolvedPresentation.flatRenderState, relief: frameContext.services.groundRelief)
        case .spherical:
            let globe = frameContext.globeRenderUniform
            surface = .sphere(globe: globe,
                              pureSphere: GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                                             transition: globe.transition))
        }
        drawing.encode(placements: frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements,
                       cameraUniform: frameContext.cameraUniform,
                       surface: surface,
                       encoder: MetalRenderEncoder(encoder))
    }

    func handleMemoryWarning() {}

    func evict() {}
}
