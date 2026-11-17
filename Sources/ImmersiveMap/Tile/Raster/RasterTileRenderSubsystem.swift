// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import simd

/// The ground of the raster targets, the slots of a ring rule with a raster
/// size (`VisibleContentState.rasterTiles`): the vector path with one step
/// between, a texture. The placements are the vector placements
/// (`TilePlacementState.placeTilesContext`), the targets' own tiles and
/// the descendants and ancestors standing in for them, kept and released
/// as every vector tile is. A tile placed in a raster slot has its fills
/// drawn into a texture of the slot's size (`prepareGPU`, before the world
/// pass, the zoom fades at the planning zoom as the vector ground draws
/// them, then the mip chain), and the world pass draws the texture on the
/// tile's grid (`RasterTileGrid`), first in the ground's layer on either
/// surface, before the vector ground. A tile keeps its texture from
/// frame to frame and is drawn into it again only when what the texture
/// shows would change (`Baked`): another tile in the slot (a new load of
/// it), another size, or a fade of one of its styles moved at the
/// planning zoom. A pan or a camera at rest draws no texture at all, and
/// a texture is never stale, never missing while its tile is in, and
/// never a hole where the vector ground would not be one. The tiles drawn
/// again in a frame are drawn in one pass, each in its own window of one
/// shared atlas, and copied from there into their textures with their mip
/// chains in one blit (`prepareGPU`). The GPU work is `RasterTileDrawer`'s,
/// on the GPU interface.
///
/// A texture is opaque and owns its pixels as an opaque fill does: it
/// writes a depth half a rank step behind the ground's first, so the
/// lines drawn over it pass and a vector tile drawn over it wins outright
/// (TileRaster.metal), and it paints the ground the planner gave its
/// tile, drawn at full extent under the tile-priority stencil
/// (`TileSourceStencilPriority`) on either surface. On the plane it takes the
/// ground shadow mask as the vector ground does, and rises by the ground
/// relief where the frame is on it (`GroundReliefFrame`), on a grid as
/// fine as the zoom's flattening grid but no finer than its terrain and
/// its raster can show (`RasterTileGrid.reliefCells`). On the sphere it follows the
/// unroll as the sphere's tiles do.
final class RasterTileRenderSubsystem: RenderSubsystem {
    let name: String = "RasterTiles"

    /// One tile drawn into a texture this frame, and where it is drawn:
    /// once per wrap copy of the flat world it is placed at.
    private struct Source {
        let metalTile: MetalTile
        var size: Int
        var texture: (any GPUTexture)?
        var placements: [Placement] = []
        /// What the texture is drawn from this frame (`bakeSignature`),
        /// and whether it must be drawn into again for it.
        var signature: UInt64 = 0
        var needsBake = false
    }

    /// A tile's texture as it was last drawn: by which tile object (kept,
    /// so its identity is never another tile's), at which size, from which
    /// fades (`bakeSignature`), nil until the draw is encoded.
    private struct Baked {
        let metalTile: MetalTile
        let size: Int
        var signature: UInt64?
        let texture: any GPUTexture
    }

    /// A wrap copy a source is drawn at, and the terrain it shades by and
    /// rises by there: the finest of its placements' (`PlaceTile.terrain`,
    /// `displacement`), nil on the plane.
    private struct Placement {
        let worldWrap: Int8
        var terrain: Tile?
        var displacement: Tile?
    }

    private let device: any GPUDevice
    private let pipeline: RasterTilePipeline
    private let grid: RasterTileGrid
    private let sampler: (any GPUSampler)?
    private let mipLevelBias: Float
    private let groundOwnerState: any GPUDepthStencilState
    private let sphereOpaqueOwnerState: any GPUDepthStencilState
    private let depthDisabledState: any GPUDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture
    /// The shadow map the relief's draws sample at their raised points
    /// (`GroundShadowMaskBinding.cascades`), and its depth fallback.
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    /// The frame's sources, by the tile drawn, finest first.
    private var sources: [Source] = []
    /// The textures of the tiles drawn in raster slots, as last drawn.
    private var bakedByTile: [Tile: Baked] = [:]
    /// The textures of the tiles that left the raster slots, by size, for
    /// the next ones: a pan trades a few each frame.
    private var freeTextures: [Int: [any GPUTexture]] = [:]
    /// The atlas the frame's draws go through: multisampled (memoryless
    /// where the GPU keeps a pass's samples on chip) and resolved, grown to
    /// the largest frame's need.
    private var bakeAtlas: RasterTileDrawer.BakeAtlas?
    /// The textures this frame's pass draws, recorded as drawn once the
    /// frame is committed (`frameCommitted`): a frame dropped after its
    /// encoding never ran its pass, and its tiles draw again.
    private var pendingBakes: [(tile: Tile, texture: any GPUTexture, signature: UInt64)] = []

    /// How many free textures a size keeps: the frames of a pan, where the
    /// need moves by a few.
    static let poolSlack = 16
    /// The steps a style's fade is drawn in a texture at: the texture is
    /// drawn again when a fade moves by a step, at most a 64th of its
    /// alpha off between two draws, under anything the eye sees.
    static let fadeSteps: Float = 64

    init(device: any GPUDevice,
         pipeline: RasterTilePipeline,
         settings: ImmersiveMapSettings.TileSettings.RasterizationSettings,
         groundOwnerState: any GPUDepthStencilState,
         sphereOpaqueOwnerState: any GPUDepthStencilState,
         depthDisabledState: any GPUDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture,
         shadowMapTextureProvider: @escaping () -> MTLTexture? = { nil },
         shadowFallbackTexture: MTLTexture? = nil,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init()) {
        self.device = device
        self.pipeline = pipeline
        self.groundFlattening = groundFlattening
        self.grid = RasterTileGrid(device: device)
        var descriptor = GPUSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = min(max(settings.maximumAnisotropy, 1), 16)
        // The edge texels repeat past the tile: a tile's mips never reach
        // into the texture's opposite side.
        descriptor.addressModeU = .clampToEdge
        descriptor.addressModeV = .clampToEdge
        self.sampler = device.makeSampler(descriptor)
        self.mipLevelBias = settings.mipLevelBias
        self.groundOwnerState = groundOwnerState
        self.sphereOpaqueOwnerState = sphereOpaqueOwnerState
        self.depthDisabledState = depthDisabledState
        self.debugOverlayControls = debugOverlayControls
        self.groundShadowMaskTextureProvider = groundShadowMaskTextureProvider
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
    }

    // MARK: - The frame's sources

    /// The frame's raster placements, grouped by the tile drawn: a tile
    /// placed in several raster slots draws into one texture, of the
    /// largest size among them, and is drawn once per wrap copy it is
    /// placed at, at full extent. The placement prepass has settled which
    /// source a pixel shows (`TileSourceStencilPriority`), and the sources
    /// are ordered finest first for the pipeline's sake alone.
    func update(frameContext: FrameContext) {
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        sources.removeAll(keepingCapacity: true)
        pendingBakes.removeAll(keepingCapacity: true)
        guard placements.contains(where: { $0.rules.raster != nil }) else {
            keepTextures(of: [])
            return
        }
        // A source has one representation a frame: a tile drawn as
        // geometry anywhere (a stand-in carrying the vector rules it was
        // shown with, `TilePlacementPlanner`) draws no texture, its
        // geometry at full extent covers its raster slots too. Drawn both
        // ways, the two would share one stencil mark and meet by depth,
        // which on a relief, where their meshes sample the terrain apart,
        // leaves patches of each.
        let vectorTiles = Set(placements.filter { $0.rules.raster == nil }.map(\.metalTile.tile))
        var indexByTile: [Tile: Int] = [:]
        for placeTile in placements {
            // A raster placement (`TileDrawRules.raster`): a raster slot's
            // own tile, or a stand-in drawn as its own raster slot draws it.
            guard let target = placeTile.rules.raster, vectorTiles.contains(placeTile.metalTile.tile) == false else { continue }
            let tile = placeTile.metalTile.tile
            let index: Int
            if let found = indexByTile[tile] {
                index = found
                sources[index].size = max(sources[index].size, target.size)
            } else {
                index = sources.count
                indexByTile[tile] = index
                sources.append(Source(metalTile: placeTile.metalTile, size: target.size))
            }
            let worldWrap = placeTile.placeIn.worldWrap
            if let placement = sources[index].placements.firstIndex(where: { $0.worldWrap == worldWrap }) {
                if let terrain = placeTile.terrain, terrain.z > (sources[index].placements[placement].terrain?.z ?? -1) {
                    sources[index].placements[placement].terrain = terrain
                }
                if let displacement = placeTile.displacement,
                   displacement.z > (sources[index].placements[placement].displacement?.z ?? -1) {
                    sources[index].placements[placement].displacement = displacement
                }
            } else {
                sources[index].placements.append(Placement(worldWrap: worldWrap,
                                                           terrain: placeTile.terrain,
                                                           displacement: placeTile.displacement))
            }
        }
        if frameContext.renderSurfaceMode == .flat {
            sources.sort { Self.reference(of: $0) > Self.reference(of: $1) }
        } else {
            sources.sort { $0.metalTile.tile.z > $1.metalTile.tile.z }
        }
        // Each its texture as last drawn, or one to draw into: its own
        // when it has one of its size, else a free one.
        var fade = TileOverviewFadeUniform(pixelsPerPoint: 1, cameraZoom: Float(frameContext.planningZoom))
        for index in sources.indices {
            let tile = sources[index].metalTile.tile
            let size = sources[index].size
            let signature = Self.bakeSignature(of: sources[index].metalTile.tileBuffers.ground, fade: &fade)
            sources[index].signature = signature
            if let baked = bakedByTile[tile], baked.size == size {
                sources[index].texture = baked.texture
                sources[index].needsBake = baked.metalTile !== sources[index].metalTile || baked.signature != signature
            } else {
                sources[index].texture = freeTexture(size: size)
                sources[index].needsBake = true
            }
        }
        keepTextures(of: sources)
    }

    /// What a tile's texture is drawn from at a zoom: its fill runs' fades,
    /// each in `fadeSteps` steps, the one thing of the draw that moves with
    /// the camera. Equal signatures of one tile draw one texture.
    private static func bakeSignature(of ground: TileBuffers.GeometryLayer, fade: inout TileOverviewFadeUniform) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for run in ground.styleRuns where run.isFillsClass {
            let step = UInt64((TileStyleFadeMath.progress(zoomFade: run.zoomFade, overviewFade: fade) * fadeSteps).rounded())
            hash = (hash ^ step) &* 1_099_511_628_211
        }
        return hash
    }

    /// Keeps the textures of `sources`, recording each as drawn for its
    /// tile (the signature once the draw is encoded), and frees the rest
    /// for the tiles to come, a size's free textures kept to `poolSlack`.
    private func keepTextures(of sources: [Source]) {
        var kept: [Tile: Baked] = [:]
        for source in sources {
            guard let texture = source.texture else { continue }
            let tile = source.metalTile.tile
            let previous = bakedByTile[tile]
            let signature = source.needsBake ? nil : previous?.signature
            kept[tile] = Baked(metalTile: source.metalTile, size: source.size, signature: signature, texture: texture)
        }
        for (tile, baked) in bakedByTile where kept[tile]?.texture !== baked.texture {
            var free = freeTextures[baked.size] ?? []
            if free.count < Self.poolSlack {
                free.append(baked.texture)
            }
            freeTextures[baked.size] = free
        }
        bakedByTile = kept
        // Out of the raster rings, every texture and the atlas go.
        if kept.isEmpty {
            freeTextures.removeAll()
            bakeAtlas = nil
        }
    }

    private func freeTexture(size: Int) -> (any GPUTexture)? {
        if var free = freeTextures[size], let texture = free.popLast() {
            freeTextures[size] = free
            return texture
        }
        return RasterTileDrawer.makeTexture(device: device, size: size)
    }

    /// The stencil value of a source (`TileSourceStencilPriority`).
    private static func reference(of source: Source) -> UInt32 {
        TileSourceStencilPriority.reference(sourceZoom: source.metalTile.tile.z)
    }


    // MARK: - The textures

    /// Draws the fills of the sources whose texture must be drawn again
    /// this frame (`Source.needsBake`), and only theirs, on the frame's
    /// command buffer (`RasterTileDrawer.bake`), at the planning zoom's
    /// fades, as the vector ground draws them. A frame that draws no
    /// texture encodes nothing.
    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        let drawn = sources.indices.filter { sources[$0].needsBake && sources[$0].texture != nil }
        guard let layout = RasterTileDrawer.atlasLayout(sizes: drawn.map { sources[$0].size }),
              let commandBuffer = frameContext.gpuCommandBuffer,
              let atlas = atlas(width: layout.width, height: layout.height) else { return }
        let bakes = drawn.compactMap { index in
            sources[index].texture.map {
                RasterTileDrawer.Bake(ground: sources[index].metalTile.tileBuffers.ground, size: sources[index].size, texture: $0)
            }
        }
        guard RasterTileDrawer.bake(bakes,
                                    atlas: atlas,
                                    commandBuffer: commandBuffer,
                                    pipeline: pipeline,
                                    baseColor: frameContext.services.baseColors.map,
                                    planningZoom: frameContext.planningZoom) else { return }
        for index in drawn {
            guard let texture = sources[index].texture else { continue }
            pendingBakes.append((sources[index].metalTile.tile, texture, sources[index].signature))
        }
    }

    /// The frame's pass is on the GPU: its textures are drawn, from the
    /// signatures they were drawn from.
    func frameCommitted() {
        for bake in pendingBakes where bakedByTile[bake.tile]?.texture === bake.texture {
            bakedByTile[bake.tile]?.signature = bake.signature
        }
        pendingBakes.removeAll(keepingCapacity: true)
    }

    /// The atlas the frame's draws go through, at least `width` by
    /// `height`, grown when a frame needs more.
    private func atlas(width: Int, height: Int) -> RasterTileDrawer.BakeAtlas? {
        if let bakeAtlas, bakeAtlas.resolved.width >= width, bakeAtlas.resolved.height >= height {
            return bakeAtlas
        }
        bakeAtlas = RasterTileDrawer.BakeAtlas.make(device: device,
                                                    width: max(width, bakeAtlas?.resolved.width ?? 0),
                                                    height: max(height, bakeAtlas?.resolved.height ?? 0))
        return bakeAtlas
    }

    // MARK: - The draws

    func encode(layer: RenderLayer, encoder: any GPURenderEncoder, frameContext: FrameContext) {
        guard sources.isEmpty == false, let sampler else { return }
        let sampling = RasterTileDrawer.Sampling(sampler: sampler,
                                                 mipLevelBias: mipLevelBias,
                                                 wireframe: debugOverlayControls.snapshot().wireframeEnabled)
        switch (layer, frameContext.renderSurfaceMode) {
        case (.flatMapSurface, .flat):
            encodeFlat(encoder: encoder, frameContext: frameContext, sampling: sampling)
        case (.globeVectorSurface, .spherical):
            encodeSphere(encoder: encoder, frameContext: frameContext, sampling: sampling)
        default:
            return
        }
    }

    /// Lets go of every texture kept from earlier frames: the tiles still
    /// in raster slots draw theirs again.
    func handleMemoryWarning() {
        bakedByTile.removeAll()
        freeTextures.removeAll()
        bakeAtlas = nil
    }

    func evict() {
        sources.removeAll()
        bakedByTile.removeAll()
        freeTextures.removeAll()
        bakeAtlas = nil
    }

    private func encodeFlat(encoder: any GPURenderEncoder,
                            frameContext: FrameContext,
                            sampling: RasterTileDrawer.Sampling) {
        let groundShadowMask = GroundShadowMaskBinding.resolve(frameContext: frameContext,
                                                               maskTexture: groundShadowMaskTextureProvider(),
                                                               fallbackTexture: groundShadowMaskFallbackTexture,
                                                               shadowMapTexture: shadowMapTextureProvider(),
                                                               shadowFallbackTexture: shadowFallbackTexture ?? groundShadowMaskFallbackTexture)
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        let groundRelief = frameContext.services.groundRelief
        var items: [RasterTileDrawer.FlatItem] = []
        for source in sources {
            guard let texture = source.texture else { continue }
            let tile = source.metalTile.tile
            for placement in source.placements {
                // The world tile is the horizon backdrop, flat on the plane
                // (`TileWorkingSetSubsystem.horizonBackdrops`): no band
                // places a tile that coarse.
                let relief = tile.z > TileCulling.flatBackdropZoomLevel
                    ? placement.displacement.flatMap { groundRelief?.relief(for: tile, terrain: $0) }
                    : nil
                let shading = relief == nil ? nil : placement.terrain.flatMap { groundRelief?.relief(for: tile, terrain: $0) }
                // As fine as the terrain and the raster can show, no finer.
                let cells = relief.map {
                    RasterTileGrid.reliefCells(gridCells: groundFlattening.grid(forTileZoom: tile.z), relief: $0, rasterSize: source.size)
                } ?? 0
                guard let mesh = grid.mesh(forTileZoom: tile.z, atLeast: cells) else { continue }
                let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                                 y: tile.y,
                                                                                 z: tile.z,
                                                                                 worldWrap: placement.worldWrap,
                                                                                 flatRenderPan: flatRenderState.pan,
                                                                                 renderMapSize: flatRenderState.renderMapSize)
                let scale = originAndSize.z / 4096.0
                // The horizon backdrop lies under the relief, at the lowest
                // height of the frame's terrain: on the plane the ground is
                // drawn from (the terrain under the point looked at) it
                // would hang over the valleys below that point, a sheet in
                // the air wherever a far tile is still on its way.
                let floorLift: Float = tile.z <= TileCulling.flatBackdropZoomLevel
                    ? Self.backdropFloorLift(relief: groundRelief)
                    : 0
                let modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                           y: originAndSize.y,
                                                           z: floorLift) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
                items.append(RasterTileDrawer.FlatItem(texture: texture,
                                                       stencilReference: Self.reference(of: source),
                                                       mesh: mesh,
                                                       modelMatrix: modelMatrix,
                                                       relief: relief.map { (relief: $0, shading: shading, tile: tile) }))
            }
        }
        RasterTileDrawer.drawFlat(items,
                                  encoder: encoder,
                                  cameraUniform: frameContext.cameraUniform,
                                  groundShadow: RasterTileDrawer.GroundShadow(
                                      uniform: groundShadowMask.uniform,
                                      mask: MetalTexture(groundShadowMask.texture, format: GroundShadowMaskPipeline.format),
                                      cascades: MetalTexture(groundShadowMask.cascades, format: ShadowCascadeAtlas.depthFormat)),
                                  groundFog: GroundFogUniform.resolve(frameContext: frameContext),
                                  groundRelief: groundRelief,
                                  renderMapSize: flatRenderState.renderMapSize,
                                  sampling: sampling,
                                  pipeline: pipeline,
                                  groundOwnerState: groundOwnerState,
                                  depthDisabledState: depthDisabledState)
    }

    /// The world z the horizon backdrop lies at on the relief: the frame's
    /// lowest terrain over the datum, in world units at the frame's rise,
    /// never over the plane. Zero off the relief.
    static func backdropFloorLift(relief: GroundReliefFrame?) -> Float {
        guard let relief, relief.isActive, let range = relief.heightRangeMetres else { return 0 }
        let metres = min(range.lowerBound - relief.datumMetres, 0)
        return metres * relief.worldUnitsPerMetre * relief.strength
    }

    private func encodeSphere(encoder: any GPURenderEncoder,
                              frameContext: FrameContext,
                              sampling: RasterTileDrawer.Sampling) {
        let globe = frameContext.globeRenderUniform
        // The sphere has one copy of the world, and a tile draws whole at
        // its own place whatever slot it stands in: once per source.
        let items = sources.compactMap { source -> RasterTileDrawer.SphereItem? in
            guard let texture = source.texture,
                  let mesh = grid.mesh(forTileZoom: source.metalTile.tile.z) else { return nil }
            return RasterTileDrawer.SphereItem(texture: texture,
                                               stencilReference: Self.reference(of: source),
                                               mesh: mesh,
                                               tile: source.metalTile.tile)
        }
        RasterTileDrawer.drawSphere(items,
                                    encoder: encoder,
                                    cameraUniform: frameContext.cameraUniform,
                                    globe: globe,
                                    globeLight: GlobeLightUniform.resolve(frameContext: frameContext),
                                    pureSphere: GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                                                  transition: globe.transition),
                                    sampling: sampling,
                                    pipeline: pipeline,
                                    sphereOpaqueOwnerState: sphereOpaqueOwnerState,
                                    depthDisabledState: depthDisabledState)
    }
}

