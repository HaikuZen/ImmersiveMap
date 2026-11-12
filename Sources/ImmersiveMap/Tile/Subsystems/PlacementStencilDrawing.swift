// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The placement prepass's draws, apart from the subsystem that reads the
/// frame (`PlacementStencilRenderSubsystem`, where the passes are
/// explained), so they build and are tested everywhere.
struct PlacementStencilDrawing {
    /// The depth and stencil states of the passes.
    struct States {
        let stencilWrite: any GPUDepthStencilState
        let depthWrite: any GPUDepthStencilState
        let stencilReliefWrite: any GPUDepthStencilState
        let depthReset: any GPUDepthStencilState
        let depthDisabled: any GPUDepthStencilState
    }

    enum Surface {
        /// The plane, with the frame's relief, nil off it.
        case flat(FlatRenderState, relief: GroundReliefFrame?)
        /// The resting sphere or the morph (`pureSphere` false).
        case sphere(globe: GlobeUniform, pureSphere: Bool)
    }

    /// How far behind the ground's surface its depth is written in the
    /// relief's first pass, in the depth's units and in units of its slope
    /// per pixel: enough for a square's mark, the same grid drawn again,
    /// to pass `lessEqual` against it through the rasterizer's rounding,
    /// and no more, so the ground behind a mountain's silhouette fails the
    /// test right at the silhouette.
    static let groundDepthBias: Float = 1
    static let groundDepthSlopeBias: Float = 1

    let pipeline: PlacementStencilPipeline
    let grid: RasterTileGrid
    let states: States
    let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    /// Writes the planner's marks for `placements`, coarse squares first: a
    /// finer placement inside a coarser one (a descendant standing in, a
    /// child target under its parent) marks over it. Leaves the encoder in
    /// its neutral state.
    func encode(placements unsorted: [PlaceTile],
                cameraUniform: CameraUniform,
                surface: Surface,
                encoder: any GPURenderEncoder) {
        let placements = unsorted.sorted { $0.placeIn.z < $1.placeIn.z }
        guard placements.isEmpty == false else { return }

        encoder.pushDebugGroup("ground.placementStencil")
        encoder.setDepthStencilState(states.stencilWrite)
        // Every grid triangle is counter-clockwise in render space and
        // neither surface mirrors: back faces are culled, which on the
        // sphere removes its far side.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        encoder.setVertexValue(cameraUniform, index: 1)
        switch surface {
        case let .flat(flatRenderState, relief):
            encodeFlat(placements: placements, encoder: encoder, flatRenderState: flatRenderState, relief: relief)
        case let .sphere(globe, pureSphere):
            encodeSphere(placements: placements, encoder: encoder, globe: globe, pureSphere: pureSphere, cameraUniform: cameraUniform)
        }
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(states.depthDisabled)
        encoder.popDebugGroup()
    }

    private func encodeFlat(placements: [PlaceTile],
                            encoder: any GPURenderEncoder,
                            flatRenderState: FlatRenderState,
                            relief: GroundReliefFrame?) {
        guard let frame = relief, frame.isActive else {
            // The plane: the marks alone, the depth untouched.
            encodeFlatMarks(placements: placements, encoder: encoder, flatRenderState: flatRenderState, frame: nil)
            return
        }
        // The horizon backdrop first, flat and with no depth: its mark is
        // under every other's, wherever the ground is, and it takes no
        // part in the ground's depth, where the plane it lies on would win
        // the valleys under the plane from the ground that is there.
        let backdrops = placements.filter(\.isHorizonBackdrop)
        let ground = placements.filter { $0.isHorizonBackdrop == false }
        if backdrops.isEmpty == false {
            encodeFlatMarks(placements: backdrops, encoder: encoder, flatRenderState: flatRenderState, frame: nil)
        }
        // The relief: the ground's depth, then the marks tested against it.
        encoder.setDepthStencilState(states.depthWrite)
        encoder.setDepthBias(GPUDepthBias(constant: Self.groundDepthBias, slopeScale: Self.groundDepthSlopeBias, clamp: 0))
        encodeFlatGroundDepth(placements: ground, encoder: encoder, flatRenderState: flatRenderState, frame: frame)
        encoder.setDepthBias(.none)
        encoder.setDepthStencilState(states.stencilReliefWrite)
        encodeFlatMarks(placements: ground, encoder: encoder, flatRenderState: flatRenderState, frame: frame)
        // The depth back to the far plane: it was the marks' to test
        // against, and the ground meets the cleared depth as before.
        encoder.pushDebugGroup("ground.placementDepthReset")
        encoder.setDepthStencilState(states.depthReset)
        encoder.setPipeline(pipeline.depthResetPipelineState)
        encoder.draw(.triangle, vertexStart: 0, vertexCount: 3)
        encoder.popDebugGroup()
    }

    /// A source's ground as the ground draws it: its relief out of the
    /// terrain its placements are bound to, and its grid's cells a side. A
    /// raster source's grid is the raster ground's
    /// (`RasterTileGrid.reliefCells`), at its raster size; a vector
    /// source's the flattening's, as the vector ground has, and so has a
    /// raster source drawn as geometry elsewhere
    /// (`RasterTileRenderSubsystem`). No relief on the plane.
    private struct SourceGround {
        let relief: GroundRelief?
        let cells: Int
    }

    private func sourceGround(tile: Tile,
                              displacement: Tile?,
                              rasterSizeByTile: [Tile: Int],
                              frame: GroundReliefFrame?) -> SourceGround {
        let gridCells = groundFlattening.grid(forTileZoom: tile.z)
        guard let displacement, let relief = frame?.relief(for: tile, terrain: displacement) else {
            return SourceGround(relief: nil, cells: 0)
        }
        let cells = rasterSizeByTile[tile].map {
            RasterTileGrid.reliefCells(gridCells: gridCells, relief: relief, rasterSize: $0)
        } ?? gridCells
        return SourceGround(relief: relief, cells: cells)
    }

    /// The relief's first pass: every point of the ground once, from the
    /// placement the planner gave it, each square a part of its source's
    /// grid on the source's own lines, lifted by the source's relief
    /// narrowed to the square. Depth only.
    private func encodeFlatGroundDepth(placements: [PlaceTile],
                                       encoder: any GPURenderEncoder,
                                       flatRenderState: FlatRenderState,
                                       frame: GroundReliefFrame) {
        let rasterSizeByTile = RasterTileGrid.rasterSizesBySource(placements)
        var grounds: [PlacementGroundSquare.Source: SourceGround] = [:]
        var selectedRelief: Bool?
        encoder.pushDebugGroup("ground.placementDepth")
        for square in PlacementGroundSquare.squares(of: placements) {
            let source = square.source
            let ground: SourceGround
            if let known = grounds[source] {
                ground = known
            } else {
                ground = sourceGround(tile: source.tile, displacement: source.displacement, rasterSizeByTile: rasterSizeByTile, frame: frame)
                grounds[source] = ground
            }
            let tile = square.square.tile
            // The source's cells over the part of it drawn, on the same
            // lines, exactly: the zoom's floor would put the part's
            // vertices between the source's.
            let squareCells = PlacementGroundSquare.cells(ofSource: ground.cells, sourceZoom: source.tile.z, squareZoom: tile.z)
            let mesh: RasterTileGrid.Mesh?
            if ground.relief != nil {
                mesh = grid.mesh(cells: squareCells)
            } else {
                mesh = grid.mesh(forTileZoom: tile.z)
            }
            guard let mesh else { continue }
            selectPipeline(relief: ground.relief != nil, selected: &selectedRelief, encoder: encoder)
            if let relief = ground.relief {
                GroundReliefUniform.bind(relief.narrowed(to: tile, in: source.tile),
                                         over: tile,
                                         frame: frame,
                                         renderMapSize: flatRenderState.renderMapSize,
                                         encoder: encoder)
            }
            setModelMatrix(tile: tile, worldWrap: square.square.worldWrap, flatRenderState: flatRenderState, encoder: encoder)
            draw(mesh: mesh, encoder: encoder)
        }
        encoder.popDebugGroup()
    }

    /// The marks: every placement's whole square, coarse first, each on
    /// its source's grid (the source's cells over the square, as the
    /// relief's first pass drew them, so a square's mark meets its own
    /// depth), lifted by the source's relief narrowed to the square, or
    /// on the plane without a relief.
    private func encodeFlatMarks(placements: [PlaceTile],
                                 encoder: any GPURenderEncoder,
                                 flatRenderState: FlatRenderState,
                                 frame: GroundReliefFrame?) {
        let rasterSizeByTile = RasterTileGrid.rasterSizesBySource(placements)
        // A source's relief is one terrain wherever it draws, so a mark
        // meets the depth the first pass drew from the same heights.
        let displacements = PlacementGroundSquare.displacements(of: placements)
        var grounds: [PlacementGroundSquare.Source: SourceGround] = [:]
        var selectedRelief: Bool?
        for placement in placements {
            let source = placement.metalTile.tile
            let tile = placement.placeIn.tile
            let sourceKey = PlacementGroundSquare.Source(
                tile: source,
                worldWrap: placement.placeIn.worldWrap,
                displacement: displacements[VisibleTile(tile: source, worldWrap: placement.placeIn.worldWrap)] ?? placement.displacement)
            let ground: SourceGround
            if let known = grounds[sourceKey] {
                ground = known
            } else {
                ground = sourceGround(tile: source, displacement: sourceKey.displacement, rasterSizeByTile: rasterSizeByTile, frame: frame)
                grounds[sourceKey] = ground
            }
            let squareCells = PlacementGroundSquare.cells(ofSource: ground.cells, sourceZoom: source.z, squareZoom: tile.z)
            let mesh: RasterTileGrid.Mesh?
            if ground.relief != nil {
                mesh = grid.mesh(cells: squareCells)
            } else {
                mesh = grid.mesh(forTileZoom: tile.z)
            }
            guard let mesh else { continue }
            selectPipeline(relief: ground.relief != nil, selected: &selectedRelief, encoder: encoder)
            if let relief = ground.relief, let frame {
                GroundReliefUniform.bind(relief.narrowed(to: tile, in: source),
                                         over: tile,
                                         frame: frame,
                                         renderMapSize: flatRenderState.renderMapSize,
                                         encoder: encoder)
            }
            setModelMatrix(tile: tile, worldWrap: placement.placeIn.worldWrap, flatRenderState: flatRenderState, encoder: encoder)
            encoder.setStencilReference(TileSourceStencilPriority.reference(sourceZoom: source.z))
            draw(mesh: mesh, encoder: encoder)
        }
    }

    /// The relief variant for a square whose terrain is in, the plain one
    /// for the rest, selected only where it changes from the last draw.
    private func selectPipeline(relief: Bool, selected: inout Bool?, encoder: any GPURenderEncoder) {
        guard selected != relief else { return }
        selected = relief
        encoder.setPipeline(relief ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
    }

    private func setModelMatrix(tile: Tile, worldWrap: Int8, flatRenderState: FlatRenderState, encoder: any GPURenderEncoder) {
        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         worldWrap: worldWrap,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0
        let modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                   y: originAndSize.y,
                                                   z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
        encoder.setVertexValue(modelMatrix, index: 3)
    }

    /// The sphere has one copy of the world: a placement's square is its
    /// tile's place on the sphere, as the raster tile draws it.
    private func encodeSphere(placements: [PlaceTile],
                              encoder: any GPURenderEncoder,
                              globe: GlobeUniform,
                              pureSphere: Bool,
                              cameraUniform: CameraUniform) {
        encoder.setPipeline(pureSphere ? pipeline.spherePurePipelineState : pipeline.sphereMorphPipelineState)
        let globeValue = globe
        let globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: cameraUniform.matrix)
        encoder.setVertexValue(globeValue, index: 8)
        encoder.setVertexValue(globeFrame, index: 10)
        for placement in placements {
            let tile = placement.placeIn.tile
            guard let mesh = grid.mesh(forTileZoom: tile.z) else { continue }
            let surfaceTile = GlobeSurfaceTileUniform(tile: tile)
            encoder.setVertexValue(surfaceTile, index: 9)
            encoder.setStencilReference(TileSourceStencilPriority.reference(sourceZoom: placement.metalTile.tile.z))
            draw(mesh: mesh, encoder: encoder)
        }
    }

    private func draw(mesh: RasterTileGrid.Mesh, encoder: any GPURenderEncoder) {
        encoder.setVertexBuffer(mesh.gpuVertices, offset: 0, index: 0)
        encoder.drawIndexed(.triangle,
                            indexCount: mesh.indexCount,
                            indexType: mesh.gpuIndexType,
                            indexBuffer: mesh.gpuIndices,
                            indexBufferOffset: 0)
    }
}
