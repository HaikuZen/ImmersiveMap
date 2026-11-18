// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// The raster tiles' GPU work (`RasterTileRenderSubsystem` decides which
/// tiles and when): their fills drawn into their textures, and the
/// textures drawn on the tiles' grids on the plane and on the sphere.
enum RasterTileDrawer {
    /// A tile whose texture is drawn this frame: its ground, and the
    /// texture of its size it is drawn into.
    struct Bake {
        let ground: TileBuffers.GeometryLayer
        let size: Int
        let texture: any GPUTexture
    }

    /// The atlas a frame's bakes go through: multisampled (memoryless where
    /// the GPU keeps a pass's samples on chip) and resolved.
    struct BakeAtlas {
        let samples: any GPUTexture
        let resolved: any GPUTexture

        /// An atlas of the size, nil where the device makes none.
        static func make(device: any GPUDevice, width: Int, height: Int) -> BakeAtlas? {
            var samples = GPUTextureDescriptor(format: RasterTileTexture.format, width: width, height: height)
            samples.type = .type2DMultisample
            samples.sampleCount = RasterTilePipeline.bakeSampleCount
            samples.usage = .renderTarget
            samples.storage = .memoryless
            var resolved = GPUTextureDescriptor(format: RasterTileTexture.format, width: width, height: height)
            resolved.usage = .renderTarget
            guard let samplesTexture = device.makeTexture(samples),
                  let resolvedTexture = device.makeTexture(resolved) else {
                return nil
            }
            return BakeAtlas(samples: samplesTexture, resolved: resolvedTexture)
        }
    }

    /// A texture of a raster tile of the size: mipmapped, drawn into by the
    /// copies of `bake` and sampled by the draws.
    static func makeTexture(device: any GPUDevice, size: Int) -> (any GPUTexture)? {
        var descriptor = GPUTextureDescriptor(format: RasterTileTexture.format, width: size, height: size)
        descriptor.mipmapLevelCount = mipLevelCount(size: size)
        descriptor.usage = [.shaderRead, .renderTarget]
        return device.makeTexture(descriptor)
    }

    /// The levels of a full mip chain of a square of the side.
    static func mipLevelCount(size: Int) -> Int {
        var levels = 1
        var side = max(size, 1)
        while side > 1 {
            side /= 2
            levels += 1
        }
        return levels
    }

    /// The atlas side a frame's bakes need: windows of the largest size,
    /// in a square of columns. Nil for no bake.
    static func atlasLayout(sizes: [Int]) -> (cell: Int, columns: Int, width: Int, height: Int)? {
        guard sizes.isEmpty == false else { return nil }
        let cell = sizes.reduce(0, max)
        let columns = Int(Double(sizes.count).squareRoot().rounded(.up))
        let rows = (sizes.count + columns - 1) / columns
        return (cell, columns, columns * cell, rows * cell)
    }

    /// Draws the fills of each bake, and only theirs, in one pass on the
    /// command buffer: each in its own window of the atlas, through the
    /// atlas's samples, resolved at the pass's end. Then one blit copies
    /// each window into its texture and makes the texture's mip chain. The
    /// fades are the zoom's, as the vector ground draws them, over the
    /// map's base colour. The atlas is at least `atlasLayout`'s size.
    /// False when the command buffer made no encoder.
    static func bake(_ bakes: [Bake],
                     atlas: BakeAtlas,
                     commandBuffer: any GPUCommandBuffer,
                     pipeline: RasterTilePipeline,
                     baseColor: SIMD4<Float>,
                     planningZoom: Double) -> Bool {
        guard let layout = atlasLayout(sizes: bakes.map(\.size)) else { return true }
        var color = GPUColorAttachment(texture: atlas.samples)
        color.resolveTexture = atlas.resolved
        color.load = .clear
        color.clearColor = GPUClearColor(red: Double(baseColor.x), green: Double(baseColor.y),
                                         blue: Double(baseColor.z), alpha: 1)
        color.store = .multisampleResolve
        var pass = GPURenderPassDescriptor(colorAttachments: [color])
        pass.label = "RasterTiles \(bakes.count)"
        guard let encoder = commandBuffer.makeRenderEncoder(pass) else { return false }
        encoder.setPipeline(pipeline.bakePipelineState)
        encoder.setCullMode(.none)
        var fade = TileOverviewFadeUniform(pixelsPerPoint: 1, cameraZoom: Float(planningZoom))
        var origins: [(x: Int, y: Int)] = []
        for (slot, bake) in bakes.enumerated() {
            let origin = (x: (slot % layout.columns) * layout.cell, y: (slot / layout.columns) * layout.cell)
            // The tile's extent fills its window: the clip volume is the
            // window, so nothing of a tile reaches its neighbour's.
            encoder.setViewport(GPUViewport(x: Double(origin.x), y: Double(origin.y),
                                            width: Double(bake.size), height: Double(bake.size)))
            encoder.setScissorRect(GPUScissorRect(x: origin.x, y: origin.y, width: bake.size, height: bake.size))
            encodeFills(of: bake.ground, fade: &fade, encoder: encoder)
            origins.append(origin)
        }
        encoder.endEncoding()

        guard let blit = commandBuffer.makeBlitEncoder() else { return false }
        for (bake, origin) in zip(bakes, origins) {
            blit.copy(from: atlas.resolved, slice: 0, mipmapLevel: 0, x: origin.x, y: origin.y,
                      to: bake.texture, destinationSlice: 0, destinationMipmapLevel: 0,
                      destinationX: 0, destinationY: 0, width: bake.size, height: bake.size)
            blit.generateMipmaps(for: bake.texture)
        }
        blit.endEncoding()
        return true
    }

    /// The fill runs of a ground layer, in buffer order (bottom to top),
    /// adjacent runs in one draw. The ribbons are left out: the lines are
    /// never in a raster tile. A run faded out at the frame's zoom is left
    /// out, as the vector ground leaves it out, and the rest take their
    /// fade's alpha in the shader. A layer without a run table draws
    /// nothing, as the vector ground's class passes do.
    private static func encodeFills(of ground: TileBuffers.GeometryLayer,
                                    fade: inout TileOverviewFadeUniform,
                                    encoder: any GPURenderEncoder) {
        guard ground.indicesCount > 0,
              let indices = ground.indices,
              let vertices = ground.vertices,
              let styles = ground.styles,
              let styleZoomFade = ground.styleZoomFade else { return }
        encoder.setVertexBuffer(vertices.gpuBuffer, offset: vertices.offset, index: 0)
        encoder.setVertexBuffer(styles.gpuBuffer, offset: styles.offset, index: 2)
        encoder.setVertexBuffer(styleZoomFade.gpuBuffer, offset: styleZoomFade.offset, index: 4)
        encoder.setVertexValue(fade, index: 11)
        let indexByteWidth = ground.gpuIndexType.byteCount
        var spanStart = 0
        var spanCount = 0
        func flush() {
            guard spanCount > 0 else { return }
            encoder.drawIndexed(.triangle,
                                indexCount: spanCount,
                                indexType: ground.gpuIndexType,
                                indexBuffer: indices.gpuBuffer,
                                indexBufferOffset: indices.offset + spanStart * indexByteWidth,
                                instanceCount: 1,
                                baseVertex: 0,
                                baseInstance: 0)
            spanCount = 0
        }
        for run in ground.styleRuns {
            guard run.indexCount > 0,
                  run.isFillsClass,
                  TileStyleFadeMath.fadeIsZero(zoomFade: run.zoomFade, overviewFade: fade) == false else {
                flush()
                continue
            }
            if spanCount > 0, spanStart + spanCount == Int(run.indexStart) {
                spanCount += Int(run.indexCount)
            } else {
                flush()
                spanStart = Int(run.indexStart)
                spanCount = Int(run.indexCount)
            }
        }
        flush()
    }

    // MARK: - The draws

    /// What every draw of a frame shares.
    struct Sampling {
        let sampler: any GPUSampler
        let mipLevelBias: Float
        /// The debug panel's triangle edges.
        let wireframe: Bool
    }

    /// A tile's texture drawn at one place on the plane.
    struct FlatItem {
        let texture: any GPUTexture
        /// The tile-priority value, tested equal to the planner's marks
        /// (`TileSourceStencilPriority`).
        let stencilReference: UInt32
        let mesh: RasterTileGrid.Mesh
        let modelMatrix: matrix_float4x4
        /// The terrain the tile rises by and shades by, and the tile it is
        /// over, nil off the relief.
        let relief: (relief: GroundRelief, shading: GroundRelief?, tile: Tile)?
    }

    /// The ground shadow mask the plane's draws take, and the cascades the
    /// relief's variant samples at its raised points.
    struct GroundShadow {
        let uniform: ShadowUniform
        let mask: any GPUTexture
        let cascades: any GPUTexture
    }

    /// The textures on the plane, under the ground owner's stencil test:
    /// the relief variant for a tile on the relief, the plain one for the
    /// rest, selected only where it changes from the last draw.
    static func drawFlat(_ items: [FlatItem],
                         encoder: any GPURenderEncoder,
                         cameraUniform: CameraUniform,
                         groundShadow: GroundShadow,
                         groundFog: GroundFogUniform,
                         groundRelief: GroundReliefFrame?,
                         renderMapSize: Double,
                         sampling: Sampling,
                         pipeline: RasterTilePipeline,
                         groundOwnerState: any GPUDepthStencilState,
                         depthDisabledState: any GPUDepthStencilState) {
        encoder.pushDebugGroup("ground.rasterTiles")
        beginDraws(encoder: encoder, sampling: sampling)
        encoder.setPipeline(pipeline.flatPipelineState)
        encoder.setDepthStencilState(groundOwnerState)
        encoder.setVertexValue(cameraUniform, index: 1)
        encoder.setFragmentValue(groundShadow.uniform, index: 3)
        encoder.setFragmentTexture(groundShadow.mask, index: 1)
        encoder.setFragmentTexture(groundShadow.cascades, index: 2)
        GroundFogUniform.bind(groundFog, encoder: encoder)
        var selectedRelief = false
        for item in items {
            encoder.setFragmentTexture(item.texture, index: 0)
            encoder.setStencilReference(item.stencilReference)
            if (item.relief != nil) != selectedRelief {
                selectedRelief = item.relief != nil
                encoder.setPipeline(selectedRelief ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
            }
            if let relief = item.relief, let groundRelief {
                GroundReliefUniform.bind(relief.relief,
                                         shading: relief.shading,
                                         over: relief.tile,
                                         frame: groundRelief,
                                         renderMapSize: renderMapSize,
                                         encoder: encoder)
            }
            encoder.setVertexValue(item.modelMatrix, index: 3)
            draw(mesh: item.mesh, encoder: encoder)
        }
        endDraws(encoder: encoder, depthDisabledState: depthDisabledState)
        encoder.popDebugGroup()
    }

    /// A tile's texture on the sphere, whole at its own place.
    struct SphereItem {
        let texture: any GPUTexture
        let stencilReference: UInt32
        let mesh: RasterTileGrid.Mesh
        let tile: Tile
    }

    /// The textures on the sphere, or on the morph toward the plane,
    /// under the sphere's opaque owner state, shaded by the sun on the
    /// globe as the vector surface is.
    static func drawSphere(_ items: [SphereItem],
                           encoder: any GPURenderEncoder,
                           cameraUniform: CameraUniform,
                           globe: GlobeUniform,
                           globeLight: GlobeLightUniform,
                           pureSphere: Bool,
                           sampling: Sampling,
                           pipeline: RasterTilePipeline,
                           sphereOpaqueOwnerState: any GPUDepthStencilState,
                           depthDisabledState: any GPUDepthStencilState) {
        encoder.pushDebugGroup("ground.rasterTiles")
        beginDraws(encoder: encoder, sampling: sampling, globeLight: globeLight)
        encoder.setPipeline(pureSphere ? pipeline.spherePurePipelineState : pipeline.sphereMorphPipelineState)
        encoder.setDepthStencilState(sphereOpaqueOwnerState)
        encoder.setVertexValue(cameraUniform, index: 1)
        encoder.setVertexValue(globe, index: 8)
        encoder.setVertexValue(GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: cameraUniform.matrix), index: 10)
        for item in items {
            encoder.setVertexValue(GlobeSurfaceTileUniform(tile: item.tile), index: 9)
            encoder.setStencilReference(item.stencilReference)
            encoder.setFragmentTexture(item.texture, index: 0)
            draw(mesh: item.mesh, encoder: encoder)
        }
        endDraws(encoder: encoder, depthDisabledState: depthDisabledState)
        encoder.popDebugGroup()
    }

    /// Every grid triangle is counter-clockwise in render space, as every
    /// tile triangle is, and neither surface mirrors: back faces are culled,
    /// which on the sphere removes its far side.
    /// `globeLight` is the sun on the globe, which the sphere's rings shade
    /// by as the vector surface does, none on the plane.
    private static func beginDraws(encoder: any GPURenderEncoder,
                                   sampling: Sampling,
                                   globeLight: GlobeLightUniform = .disabled) {
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        if sampling.wireframe {
            encoder.setTriangleFillMode(.lines)
        }
        encoder.setFragmentValue(RasterTileSamplingUniform(mipLevelBias: sampling.mipLevelBias), index: 1)
        GlobeLightUniform.bind(globeLight, encoder: encoder)
        encoder.setFragmentSampler(sampling.sampler, index: 0)
    }

    private static func endDraws(encoder: any GPURenderEncoder, depthDisabledState: any GPUDepthStencilState) {
        encoder.setTriangleFillMode(.fill)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
    }

    private static func draw(mesh: RasterTileGrid.Mesh, encoder: any GPURenderEncoder) {
        encoder.setVertexBuffer(mesh.gpuVertices, offset: 0, index: 0)
        encoder.drawIndexed(.triangle,
                            indexCount: mesh.indexCount,
                            indexType: mesh.gpuIndexType,
                            indexBuffer: mesh.gpuIndices,
                            indexBufferOffset: 0,
                            instanceCount: 1,
                            baseVertex: 0,
                            baseInstance: 0)
    }
}
