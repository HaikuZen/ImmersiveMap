// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

/// The engine's immutable GPU resources for one device, colour format and
/// sample count: the depth and stencil states, the fallback textures, the
/// pipelines, the globe caps' geometry and the text atlases, all made
/// through the GPU interface, so any backend builds them. The Apple host
/// keeps one per sample count for the whole process
/// (`SharedRenderResources`), with what only Apple's platforms make beside
/// it (the avatars' resources, the POI icons' atlas).
///
/// Immutable after creation and safe to read from any thread
/// (`@unchecked Sendable`: the GPU objects are, as Metal's, and nothing here
/// changes).
final class RenderResources: @unchecked Sendable {
    /// The device every resource here was made with.
    let device: any GPUDevice
    let renderSampleCount: Int
    /// The colour format the world and overlay passes render in.
    let colorFormat: GPUPixelFormat

    // MARK: - Depth states and fallback textures

    let extrudedDepthState: any GPUDepthStencilState
    /// The label passes: lessEqual with the write on. The labels rasterize
    /// at the far plane and their fragments write one of two depths just
    /// short of it (TextShader.metal), fill nearer than halo, so a later
    /// glyph's halo never covers an earlier glyph's fill.
    let labelDepthState: any GPUDepthStencilState
    let globeCapDepthState: any GPUDepthStencilState
    /// The sky layers (the space background and the stars): drawn first on
    /// the sphere at the far plane, tested against the cleared depth without
    /// writing; the tile geometry blends over them.
    let skyBackdropDepthState: any GPUDepthStencilState
    /// The horizon layer's ground side: the far-plane fragment passes only
    /// where something wrote a nearer depth (the ground's rank band), never
    /// written, and not where a building or a model raised the surface mask
    /// bit, so the haze reaches the painted ground alone and the sky side
    /// keeps the rest.
    let horizonGroundDepthState: any GPUDepthStencilState
    /// The world-pass scene models: scene depth plus the surface mask write
    /// (see `TileSourceStencilPriority.surfaceMaskBit`).
    let sceneModelSurfaceMaskState: any GPUDepthStencilState
    /// The four draws of a scene model that cuts into the ground (see
    /// `TileSourceStencilPriority.groundHoleBit` and SceneModel.metal).
    let sceneModelGroundCutStates: SceneModelGroundCutStates
    let depthDisabledState: any GPUDepthStencilState
    /// The flat ground: tested against the depth the opaque buildings wrote
    /// before it (strictly closer wins, so a wall base never loses to the
    /// ground plane it stands on), never written, since every ground layer
    /// is blended and lies on the same plane. Under a solid building the
    /// ground fails the test before its fragment is shaded.
    let groundDepthState: any GPUDepthStencilState
    /// The tile-priority stencil states (TileSourceStencilPriority), every
    /// one testing `equal` to the source's zoom, the planner's mark, and
    /// none writing the priority: the sphere's opaque ground (scene depth
    /// written) and the non-owning test for the translucent fills, the
    /// ribbons, the flat road edge lines and the bridge overlay of either
    /// surface. `sphereRibbonOwnerState` is the sphere's ribbon cores: the
    /// rank depth written under a strict test (`makeSphereRibbonOwnerDescriptor`).
    let sphereOpaqueOwnerState: any GPUDepthStencilState
    let sphereRibbonOwnerState: any GPUDepthStencilState
    let tileStencilTestState: any GPUDepthStencilState
    /// The flat ground's opaque pass: the ground depth written, so a pixel
    /// is shaded once by its topmost opaque layer, under the tile-priority
    /// test.
    let groundOwnerState: any GPUDepthStencilState
    /// The flat road buckets: the rank depth tested and written
    /// (`RoadRankDepth`), under the tile-priority test.
    let roadRankState: any GPUDepthStencilState
    /// The world-pass buildings: the scene depth (lessEqual, written, for
    /// their own walls and roofs) plus the tile-priority stencil test, which
    /// replaces the old per-placement slot clip.
    let extrudedStencilTestState: any GPUDepthStencilState
    /// The placement prepass (`PlacementStencilRenderSubsystem`): the depth
    /// neither tested nor written, the source's zoom written into the
    /// priority bits.
    let placementStencilWriteState: any GPUDepthStencilState
    /// The placement prepass on the relief (`PlacementStencilRenderSubsystem`):
    /// first the ground's depth, every point once, the stencil untouched,
    /// then the marks tested against that depth and writing none.
    let placementDepthWriteState: any GPUDepthStencilState
    let placementStencilReliefWriteState: any GPUDepthStencilState
    /// The prepass's depth reset: the depth written whatever is there, the
    /// stencil untouched.
    let placementDepthResetState: any GPUDepthStencilState
    /// Bound at the shadow-map slot when the shadow pass is skipped: receiver
    /// shaders reference the texture statically and a backend's validation requires a
    /// bound depth texture even though strength = 0 skips the sampling branch.
    /// Depth textures cannot be filled from the CPU, so a one-time no-draw pass
    /// clears this 1x1 texture to 1.0 ("lit everywhere") at creation.
    let shadowFallbackTexture: any GPUTexture
    /// Bound at the scene depth slot of the road labels on a frame whose
    /// depth was not kept for them (`RoadLabelDrawSubsystem`): the shader
    /// skips the read when the uniform says so, but the binding itself is
    /// mandatory, and it has to be a plain `depth2d`, which the shadow map's
    /// texture array is not. A 1x1 depth texture cleared to the far plane.
    let sceneDepthFallbackTexture: any GPUTexture
    /// Bound at the ground shadow mask slot of the flat ground pipeline when
    /// the mask pass did not run this frame: the shader guards the read with
    /// the disabled uniform's zero strength, but the binding itself is
    /// mandatory. A 1x1 "lit" texel, filled from the CPU.
    let groundShadowMaskFallbackTexture: any GPUTexture

    // MARK: - Pipelines

    let polygonPipeline: PolygonsPipeline
    let tilePipeline: TilePipeline
    /// The tile geometry drawn straight onto the sphere in the world pass.
    let globeVectorSurfacePipeline: TilePipeline
    /// The labels painted on the map, in the world pass on both surfaces.
    let surfaceLabelPipeline: SurfaceLabelPipeline
    let extrudedTilePipeline: ExtrudedTilePipeline
    /// The raster tiles: their bake and their draws on both surfaces.
    let rasterTilePipeline: RasterTilePipeline
    let groundShadowMaskPipeline: GroundShadowMaskPipeline
    let fxaaPipeline: FXAAPipeline
    let starfieldPipeline: StarfieldPipeline
    /// The air around the surface's edge, on both surfaces.
    let horizonPipeline: HorizonPipeline
    let sceneModelPipeline: SceneModelPipeline
    /// The models of the model tiles, see `ModelTilePipeline`.
    let modelTilePipeline: ModelTilePipeline
    /// The trees of the woods and the parks, see `TreeRenderSubsystem`.
    let treePipeline: TreePipeline
    /// The layers of the app's data, see `LayerRenderSubsystem`.
    let layerPipeline: LayerPipeline
    /// The flat map's placement prepass, see `PlacementStencilRenderSubsystem`.
    let placementStencilPipeline: PlacementStencilPipeline

    // MARK: - Geometry and atlases

    let globeCap: GlobeCapRenderer.SharedResources
    let textRenderer: TextRenderer

    /// `resource` finds the engine's resource files (the text atlases) by
    /// name and extension.
    init(device: any GPUDevice,
         colorFormat: GPUPixelFormat,
         sampleCount: Int,
         resource: @escaping @Sendable (_ name: String, _ extension: String) -> URL?) {
        self.device = device
        self.renderSampleCount = sampleCount
        self.colorFormat = colorFormat
        func state(_ descriptor: GPUDepthStencilDescriptor) -> any GPUDepthStencilState {
            guard let state = device.makeDepthStencilState(descriptor) else {
                fatalError("The device made no depth and stencil state")
            }
            return state
        }
        extrudedDepthState = state(Self.makeSceneDepthDescriptor())
        labelDepthState = state(Self.makeSceneDepthDescriptor())
        globeCapDepthState = state(Self.makeGlobeCapDepthDescriptor())
        skyBackdropDepthState = state(Self.makeSkyBackdropDepthDescriptor())
        horizonGroundDepthState = state(Self.makeHorizonGroundDepthDescriptor())
        depthDisabledState = state(Self.makeDepthDisabledDescriptor())
        groundDepthState = state(Self.makeGroundDepthDescriptor())
        sphereOpaqueOwnerState = state(Self.makeSphereOpaqueOwnerDescriptor())
        sphereRibbonOwnerState = state(Self.makeSphereRibbonOwnerDescriptor())
        tileStencilTestState = state(Self.makeTileStencilTestDescriptor())
        groundOwnerState = state(Self.makeGroundOwnerDescriptor())
        roadRankState = state(Self.makeRoadRankDescriptor())
        extrudedStencilTestState = state(Self.makeExtrudedStencilTestDescriptor())
        placementStencilWriteState = state(Self.makePlacementStencilWriteDescriptor())
        placementDepthWriteState = state(Self.makePlacementDepthWriteDescriptor())
        placementStencilReliefWriteState = state(Self.makePlacementStencilReliefWriteDescriptor())
        placementDepthResetState = state(Self.makePlacementDepthResetDescriptor())
        sceneModelSurfaceMaskState = state(Self.makeSceneModelSurfaceMaskDescriptor())
        sceneModelGroundCutStates = SceneModelGroundCutStates(
            holeWrite: state(Self.makeSceneModelGroundHoleDescriptor(raises: true)),
            holeClear: state(Self.makeSceneModelGroundHoleDescriptor(raises: false)),
            holeTest: state(Self.makeSceneModelGroundHoleTestDescriptor()))
        shadowFallbackTexture = Self.makeShadowFallbackTexture(device: device)
        sceneDepthFallbackTexture = Self.makeSceneDepthFallbackTexture(device: device)
        groundShadowMaskFallbackTexture = Self.makeGroundShadowMaskFallbackTexture(device: device)

        var polygonPipeline: PolygonsPipeline?
        var tilePipeline: TilePipeline?
        var globeVectorSurfacePipeline: TilePipeline?
        var surfaceLabelPipeline: SurfaceLabelPipeline?
        var extrudedTilePipeline: ExtrudedTilePipeline?
        var rasterTilePipeline: RasterTilePipeline?
        var groundShadowMaskPipeline: GroundShadowMaskPipeline?
        var fxaaPipeline: FXAAPipeline?
        var starfieldPipeline: StarfieldPipeline?
        var horizonPipeline: HorizonPipeline?
        var sceneModelPipeline: SceneModelPipeline?
        var modelTilePipeline: ModelTilePipeline?
        var treePipeline: TreePipeline?
        var layerPipeline: LayerPipeline?
        var placementStencilPipeline: PlacementStencilPipeline?
        var globeCap: GlobeCapRenderer.SharedResources?
        var textRenderer: TextRenderer?

        // Each job writes its own variable, so the jobs run side by side
        // with nothing shared between them.
        nonisolated(unsafe) let jobs: [() -> Void] = [
            // The heaviest groups go first so they overlap the whole batch.
            { textRenderer = TextRenderer(device: device, resource: resource, sampleCount: 1) },
            { globeCap = GlobeCapRenderer.SharedResources.make(device: device,
                                                               pixelFormat: colorFormat,
                                                               sampleCount: sampleCount,
                                                               maxLatitude: WebMercatorMath.maxLatitudeRadians) },
            { extrudedTilePipeline = ExtrudedTilePipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { polygonPipeline = PolygonsPipeline(device: device, pixelFormat: colorFormat) },
            { tilePipeline = TilePipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount,
                                          readsGroundShadowMask: true) },
            { groundShadowMaskPipeline = GroundShadowMaskPipeline(device: device) },
            { rasterTilePipeline = RasterTilePipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { globeVectorSurfacePipeline = TilePipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount,
                                                        surface: .sphere) },
            { surfaceLabelPipeline = SurfaceLabelPipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { fxaaPipeline = FXAAPipeline(device: device, pixelFormat: colorFormat) },
            { starfieldPipeline = StarfieldPipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { horizonPipeline = HorizonPipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { sceneModelPipeline = SceneModelPipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { modelTilePipeline = ModelTilePipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { placementStencilPipeline = PlacementStencilPipeline(device: device, pixelFormat: colorFormat,
                                                                  sampleCount: sampleCount) },
            { treePipeline = TreePipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
            { layerPipeline = LayerPipeline(device: device, pixelFormat: colorFormat, sampleCount: sampleCount) },
        ]
        Self.runSideBySide(jobs)

        self.polygonPipeline = polygonPipeline!
        self.tilePipeline = tilePipeline!
        self.globeVectorSurfacePipeline = globeVectorSurfacePipeline!
        self.surfaceLabelPipeline = surfaceLabelPipeline!
        self.extrudedTilePipeline = extrudedTilePipeline!
        self.rasterTilePipeline = rasterTilePipeline!
        self.groundShadowMaskPipeline = groundShadowMaskPipeline!
        self.fxaaPipeline = fxaaPipeline!
        self.starfieldPipeline = starfieldPipeline!
        self.horizonPipeline = horizonPipeline!
        self.sceneModelPipeline = sceneModelPipeline!
        self.modelTilePipeline = modelTilePipeline!
        self.treePipeline = treePipeline!
        self.layerPipeline = layerPipeline!
        self.placementStencilPipeline = placementStencilPipeline!
        self.globeCap = globeCap!
        self.textRenderer = textRenderer!
    }

    /// The jobs on every core where there are threads (`concurrentPerform`
    /// returns once all of them finished), one after another where there
    /// are none (WebAssembly).
    private static func runSideBySide(_ jobs: [() -> Void]) {
#if canImport(Dispatch)
        nonisolated(unsafe) let jobs = jobs
        DispatchQueue.concurrentPerform(iterations: jobs.count) { jobs[$0]() }
#else
        for job in jobs {
            job()
        }
#endif
    }

    // MARK: - Fallback textures

    /// One lit texel for the ground pipeline's mask slot on frames without
    /// the mask pass. A color texture, so it can be filled from the CPU,
    /// which needs shared storage.
    private static func makeGroundShadowMaskFallbackTexture(device: any GPUDevice) -> any GPUTexture {
        var descriptor = GPUTextureDescriptor(format: GroundShadowMaskPipeline.format, width: 1, height: 1)
        descriptor.usage = .shaderRead
        descriptor.storage = .shared
        descriptor.label = "GroundShadowMaskFallbackTexture"
        guard let texture = device.makeTexture(descriptor) else {
            fatalError("The device made no ground shadow mask fallback")
        }
        let lit: [UInt8] = [255]
        lit.withUnsafeBytes { bytes in
            texture.replace(x: 0, y: 0, width: 1, height: 1, mipmapLevel: 0, slice: 0,
                            bytes: bytes.baseAddress!, bytesPerRow: 1)
        }
        return texture
    }

    /// One texel a window, at the far plane, for the shadow map's slot on
    /// frames without the caster passes.
    private static func makeShadowFallbackTexture(device: any GPUDevice) -> any GPUTexture {
        var descriptor = GPUTextureDescriptor(format: ShadowCascadeAtlas.depthFormat, width: 1, height: 1)
        descriptor.type = .type2DArray
        descriptor.arrayLength = ShadowCascadeAtlas.sliceCount
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.label = "ShadowFallbackTexture"
        guard let texture = device.makeTexture(descriptor) else {
            fatalError("The device made no shadow fallback")
        }
        clearToFarPlane(texture, slices: ShadowCascadeAtlas.sliceCount, device: device)
        return texture
    }

    /// One texel of depth at the far plane for the road labels' scene depth
    /// slot on frames without a kept scene depth: a plain 2D depth texture,
    /// as the shader's `depth2d` wants, cleared by the same no-draw pass.
    private static func makeSceneDepthFallbackTexture(device: any GPUDevice) -> any GPUTexture {
        var descriptor = GPUTextureDescriptor(format: ShadowCascadeAtlas.depthFormat, width: 1, height: 1)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.label = "SceneDepthFallbackTexture"
        guard let texture = device.makeTexture(descriptor) else {
            fatalError("The device made no scene depth fallback")
        }
        clearToFarPlane(texture, slices: 1, device: device)
        return texture
    }

    /// Depth textures cannot be filled from the CPU, so a no-draw pass
    /// clears each slice to the far plane, on a throwaway queue: the clears
    /// run once per build, before any view samples the textures, and the
    /// device's queue runs them first.
    private static func clearToFarPlane(_ texture: any GPUTexture, slices: Int, device: any GPUDevice) {
        guard let commandBuffer = device.makeCommandQueue()?.makeCommandBuffer() else { return }
        for slice in 0..<slices {
            commandBuffer.makeRenderEncoder(fallbackClearPass(texture: texture, slice: slice))?.endEncoding()
        }
        commandBuffer.commit()
    }

    /// The no-draw pass that leaves one slice of a fallback cleared to the
    /// far plane: one plain pass a slice, never a layered one, which the
    /// iOS Simulator does not implement (the interface's pass draws into one
    /// slice at most).
    static func fallbackClearPass(texture: any GPUTexture, slice: Int = 0) -> GPURenderPassDescriptor {
        var depth = GPUDepthStencilAttachment(texture: texture)
        depth.slice = slice
        depth.load = .clear
        depth.store = .store
        depth.clearDepth = 1.0
        return GPURenderPassDescriptor(colorAttachments: [], depthStencilAttachment: depth)
    }

    // MARK: - Depth descriptors

    private static func makeSceneDepthDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .lessEqual
        descriptor.depthWriteEnabled = true
        return descriptor
    }

    private static func makeGlobeCapDepthDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .lessEqual
        descriptor.depthWriteEnabled = false
        return descriptor
    }

    private static func makeSkyBackdropDepthDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .lessEqual
        descriptor.depthWriteEnabled = false
        return descriptor
    }

    /// The horizon layer's ground side: a far-plane fragment (z = 1) passes
    /// the greater test exactly where a nearer depth was written, which is
    /// every painted pixel, and fails on the cleared depth of the sky.
    private static func makeHorizonGroundDepthDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .greater
        descriptor.depthWriteEnabled = false
        // And not where a standing surface raised the mask bit: the haze is
        // the ground's, and a wall crossing the horizon row keeps its own
        // colour. Reference 0 through a mask of the bit alone.
        var stencil = GPUStencilFaceState()
        stencil.compare = .equal
        stencil.stencilFailure = .keep
        stencil.depthFailure = .keep
        stencil.pass = .keep
        stencil.readMask = TileSourceStencilPriority.surfaceMaskBit
        stencil.writeMask = 0
        descriptor.frontStencil = stencil
        descriptor.backStencil = stencil
        return descriptor
    }

    private static func makeGroundDepthDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .less
        descriptor.depthWriteEnabled = false
        return descriptor
    }

    /// The tile-priority stencil (TileSourceStencilPriority): the stencil
    /// holds the planner's decision, written by the placement prepass, and
    /// every tile pass tests `equal` to its source's zoom and writes
    /// nothing: a source paints the ground it was given and no other.
    /// `opaque` is the pass that lays a source's ground: it reads the
    /// priority bits alone, under the surface mask bit the buildings and
    /// the models raise, which no tile pass clears. Every other pass reads
    /// the mask bit too: a pixel a building or a model stands on carries
    /// it, which puts the value past any reference, so the ribbons, the
    /// roads and the translucent fills never paint over them, whatever
    /// the depth says over a relief, where a road biased off the ground
    /// would.
    private static func makeTilePriorityStencil(opaque: Bool) -> GPUStencilFaceState {
        var stencil = GPUStencilFaceState()
        stencil.compare = .equal
        stencil.stencilFailure = .keep
        stencil.depthFailure = .keep
        stencil.pass = .keep
        stencil.readMask = opaque
            ? TileSourceStencilPriority.priorityMask
            : TileSourceStencilPriority.priorityMask | TileSourceStencilPriority.surfaceMaskBit
        stencil.writeMask = 0
        return stencil
    }

    /// The surface mask (TileSourceStencilPriority.surfaceMaskBit): a
    /// standing surface raises the bit wherever it passes both tests, and
    /// nothing else in the stencil changes.
    private static func makeSurfaceMaskWrite(compare: GPUCompareFunction) -> GPUStencilFaceState {
        var stencil = GPUStencilFaceState()
        stencil.compare = compare
        stencil.stencilFailure = .keep
        stencil.depthFailure = .keep
        stencil.pass = .replace
        stencil.readMask = TileSourceStencilPriority.priorityMask
        stencil.writeMask = TileSourceStencilPriority.surfaceMaskBit
        return stencil
    }

    /// The sphere's opaque ground pass: the layer-rank depth (lessEqual,
    /// written) under the tile-priority test.
    private static func makeSphereOpaqueOwnerDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeSceneDepthDescriptor()
        descriptor.frontStencil = makeTilePriorityStencil(opaque: true)
        descriptor.backStencil = makeTilePriorityStencil(opaque: true)
        return descriptor
    }

    /// The sphere's ribbon cores (TilePipeline.SphereRibbonPhase.core):
    /// the rank depth written under a strict test, drawn highest rank
    /// first, so a pixel several strokes cover blends once, by the highest
    /// of them, and a second piece of the same stroke, at the same rank,
    /// is rejected where the first already painted. Under the tile-priority
    /// test with the surface mask, as every non-owning pass.
    private static func makeSphereRibbonOwnerDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .less
        descriptor.depthWriteEnabled = true
        descriptor.frontStencil = makeTilePriorityStencil(opaque: false)
        descriptor.backStencil = makeTilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The flat ground's opaque pass: the ground depth test (against the
    /// buildings), WRITING the rank band so a pixel is shaded once by its
    /// topmost opaque layer, under the tile-priority test: a source
    /// paints the ground it was given and no other, whatever the depth
    /// says there, so the sources never meet by depth. The depth test is
    /// lessEqual for a source's own layers, which stack at the band's
    /// steps, and a vector tile over a raster of the same source (its
    /// lines) lies nearer by half a step (TileRaster.metal).
    private static func makeGroundOwnerDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeGroundDepthDescriptor()
        descriptor.depthCompare = .lessEqual
        descriptor.depthWriteEnabled = true
        descriptor.frontStencil = makeTilePriorityStencil(opaque: true)
        descriptor.backStencil = makeTilePriorityStencil(opaque: true)
        return descriptor
    }

    /// The flat road buckets: the ground depth test against the ranks
    /// (`RoadRankDepth`), WRITING the rank, on the road's source's own
    /// ground (the tile-priority test). A fragment passes only where it is
    /// nearer than what is there, so an opaque road is shaded once per
    /// pixel by its highest rank, and a road that blends lands once per
    /// pixel of a rank, an equal rank failing.
    private static func makeRoadRankDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeGroundDepthDescriptor()
        descriptor.depthWriteEnabled = true
        descriptor.frontStencil = makeTilePriorityStencil(opaque: false)
        descriptor.backStencil = makeTilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The non-owning tile passes of either surface (translucent fills,
    /// ribbons, the flat road edge lines and the bridge overlay): the
    /// ground depth test plus the tile-priority test, no writes.
    private static func makeTileStencilTestDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeGroundDepthDescriptor()
        descriptor.frontStencil = makeTilePriorityStencil(opaque: false)
        descriptor.backStencil = makeTilePriorityStencil(opaque: false)
        return descriptor
    }

    /// The placement prepass on the plane and the sphere: the depth always
    /// passes and is never written, so a placement's mark lands on every
    /// pixel of its square, through the priority bits alone
    /// (`TileSourceStencilPriority`).
    private static func makePlacementStencilWriteDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeDepthDisabledDescriptor()
        descriptor.frontStencil = makePlacementMarkStencil()
        descriptor.backStencil = makePlacementMarkStencil()
        return descriptor
    }

    /// The relief's first prepass: the ground's depth, every point of it
    /// once, the nearer of two surfaces kept, the stencil untouched.
    private static func makePlacementDepthWriteDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .lessEqual
        descriptor.depthWriteEnabled = true
        return descriptor
    }

    /// The relief's marks: a placement's mark lands where its ground is
    /// the one in front, at or before the ground's depth, and the depth
    /// is left as it is.
    private static func makePlacementStencilReliefWriteDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .lessEqual
        descriptor.depthWriteEnabled = false
        descriptor.frontStencil = makePlacementMarkStencil()
        descriptor.backStencil = makePlacementMarkStencil()
        return descriptor
    }

    /// The relief's depth reset: the far plane written over every pixel,
    /// the stencil untouched, so the ground passes meet the cleared depth.
    private static func makePlacementDepthResetDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .always
        descriptor.depthWriteEnabled = true
        return descriptor
    }

    private static func makePlacementMarkStencil() -> GPUStencilFaceState {
        var stencil = GPUStencilFaceState()
        stencil.compare = .always
        stencil.stencilFailure = .keep
        stencil.depthFailure = .keep
        stencil.pass = .replace
        stencil.readMask = 0
        stencil.writeMask = TileSourceStencilPriority.priorityMask
        return stencil
    }

    /// The world-pass buildings: scene depth for their own occlusion and
    /// nothing else to test. The building coverage is a partition of the
    /// ground (`BuildingCoveragePlanner`), so no two tiles draw a building
    /// over the same ground and the tile-priority test is not needed; a
    /// wall rises into the pixels of the ground behind it, where that test
    /// would compare it against the wrong tile anyway. The surface mask bit
    /// is still raised where a building lands, for the horizon.
    private static func makeExtrudedStencilTestDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeSceneDepthDescriptor()
        descriptor.frontStencil = makeSurfaceMaskWrite(compare: .always)
        descriptor.backStencil = makeSurfaceMaskWrite(compare: .always)
        return descriptor
    }

    /// The world-pass scene models: scene depth, no priority test (a model
    /// belongs to no tile), and the surface mask bit raised where it lands.
    private static func makeSceneModelSurfaceMaskDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeSceneDepthDescriptor()
        descriptor.frontStencil = makeSurfaceMaskWrite(compare: .always)
        descriptor.backStencil = makeSurfaceMaskWrite(compare: .always)
        return descriptor
    }

    /// The ground hole's footprint draws (SceneModel.metal): depth neither
    /// tested nor written, the ground hole bit raised on every pixel of the
    /// flattened outline, or lowered again after the model.
    private static func makeSceneModelGroundHoleDescriptor(raises: Bool) -> GPUDepthStencilDescriptor {
        var descriptor = makeDepthDisabledDescriptor()
        var stencil = GPUStencilFaceState()
        stencil.compare = .always
        stencil.stencilFailure = .keep
        stencil.depthFailure = .keep
        // Replace writes the reference, which is the bit, through the mask;
        // zero clears the bit through the same mask.
        stencil.pass = raises ? .replace : .zero
        stencil.readMask = 0
        stencil.writeMask = TileSourceStencilPriority.groundHoleBit
        descriptor.frontStencil = stencil
        descriptor.backStencil = stencil
        return descriptor
    }

    /// The two model draws of the ground cut: scene depth, the surface mask
    /// bit raised where the model lands, and the ground hole bit tested
    /// alone, equal to the reference's bit, which the drawer sets raised for
    /// the draw inside the hole and clear for the draw outside it.
    private static func makeSceneModelGroundHoleTestDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = makeSceneDepthDescriptor()
        var stencil = makeSurfaceMaskWrite(compare: .equal)
        stencil.readMask = TileSourceStencilPriority.groundHoleBit
        descriptor.frontStencil = stencil
        descriptor.backStencil = stencil
        return descriptor
    }

    private static func makeDepthDisabledDescriptor() -> GPUDepthStencilDescriptor {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .always
        descriptor.depthWriteEnabled = false
        return descriptor
    }
}
