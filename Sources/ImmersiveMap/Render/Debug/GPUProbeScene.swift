// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ModelTileFormat
import PortableFoundation
import simd

/// A small scene of features already moved onto the GPU interface, drawn
/// through any backend: a sky of stars (instanced quads on a device without
/// point sprites), the globe's polar caps turning over a square of
/// flat ground with its fills and its line ribbons (its fills also drawn
/// into a raster tile's texture in a pass of their own, copied out of the
/// bake atlas, and that texture drawn on the tile's grid under them, as a
/// raster slot of the map draws), a building standing
/// on it (an extruded box, through the shadow cascades), a scene model
/// beside it (a box of the models' own layout), a model tile's tower in
/// the tile's far corner (in the baker's vertex, its two faces' colours
/// two layers of a texture array), a label painted
/// on the ground beside it, a layer of the app's (a zone, a path and a
/// point), the debug overlay's axes and the horizon's sky over all of it,
/// into the world pass's
/// targets (multisampled colour resolved into a texture of the frame's
/// size, depth and stencil), and the FXAA pass from there into the frame's
/// target, as the map draws with FXAA on. It is not the map: it is what a new backend is proven
/// with before the render core runs on it. `WebGPUFrameStreamTests` holds
/// its WebGPU stream, and the browser probe (`ImmersiveMapWebProbe`,
/// `Web/probe/`) draws it every frame.
package final class GPUProbeScene {
    private let device: any GPUDevice
    private let queue: any GPUCommandQueue
    private let caps: GlobeCapRenderer
    private let tilePipeline: TilePipeline
    private let extrudedPipeline: ExtrudedTilePipeline
    private let buildingIndexBuffers: HiddenBuildingIndexBuffers
    private let surfaceLabelPipeline: SurfaceLabelPipeline
    private let modelPipeline: SceneModelPipeline
    private let model: SceneModelMesh
    private let modelTilePipeline: ModelTilePipeline
    private let modelTile: ModelTileMesh
    private let rasterPipeline: RasterTilePipeline
    private let rasterGrid: RasterTileGrid
    private let rasterSampler: any GPUSampler
    private let rasterAtlas: RasterTileDrawer.BakeAtlas
    private let rasterTexture: any GPUTexture
    /// The raster tile's side, the smallest a ring rule gives.
    private static let rasterSize = 256
    /// The text without its atlases, which the probe does not load: the
    /// label's glyph samples an empty atlas, covers nothing and draws no
    /// pixel, while its pipeline, bindings and draws are the map's.
    private let textRenderer: TextRenderer
    private let label: SurfaceLabelDrawing.Item
    private let horizon: HorizonRenderer
    private let starPipeline: StarfieldPipeline
    private let stars: any GPUBuffer
    private let layerPipeline: LayerPipeline
    private let layer: LayerMesh
    private let groundState: any GPUDepthStencilState
    private let depthDisabledState: any GPUDepthStencilState
    private let mask: any GPUTexture
    private let cascades: any GPUTexture
    private let tile: PlaceTile
    private let fxaa: FXAAPipeline
    private let debugPolygons: PolygonsPipeline
    private let debugOverlay: DebugOverlayRenderer
    private var targets: (width: Int, height: Int, color: any GPUTexture, depth: any GPUTexture, scene: any GPUTexture)?

    /// Nil where the device makes no resource, which no backend does for
    /// these sizes.
    package init?(device: any GPUDevice) {
        guard let queue = device.makeCommandQueue(),
              let mask = device.makeTexture(GPUTextureDescriptor(format: GroundShadowMaskPipeline.format, width: 8, height: 8)) else {
            return nil
        }
        var cascadesDescriptor = GPUTextureDescriptor(format: ShadowCascadeAtlas.depthFormat, width: 8, height: 8)
        cascadesDescriptor.type = .type2DArray
        cascadesDescriptor.arrayLength = ShadowCascadeAtlas.sliceCount
        cascadesDescriptor.usage = [.shaderRead, .renderTarget]
        guard let cascades = device.makeTexture(cascadesDescriptor) else { return nil }
        var depthDescriptor = GPUDepthStencilDescriptor()
        depthDescriptor.depthCompare = .lessEqual
        depthDescriptor.depthWriteEnabled = true
        guard let groundState = device.makeDepthStencilState(depthDescriptor),
              let depthDisabledState = device.makeDepthStencilState(GPUDepthStencilDescriptor()),
              let tile = Self.groundTile(device: device),
              let label = Self.label(device: device, tile: tile.metalTile.tile),
              let layer = Self.layer(device: device),
              let stars = device.makeBuffer(Self.stars(), storage: .shared),
              let model = Self.model(device: device),
              let modelTile = Self.modelTile(device: device),
              let rasterAtlas = RasterTileDrawer.BakeAtlas.make(device: device, width: Self.rasterSize, height: Self.rasterSize),
              let rasterTexture = RasterTileDrawer.makeTexture(device: device, size: Self.rasterSize),
              let rasterSampler = Self.rasterSampler(device: device) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.mask = mask
        self.cascades = cascades
        self.groundState = groundState
        self.depthDisabledState = depthDisabledState
        self.tile = tile
        self.label = label
        self.layer = layer
        self.stars = stars
        self.model = model
        self.modelTile = modelTile
        self.rasterAtlas = rasterAtlas
        self.rasterTexture = rasterTexture
        self.rasterSampler = rasterSampler
        rasterGrid = RasterTileGrid(device: device)
        caps = GlobeCapRenderer(sharedResources: GlobeCapRenderer.SharedResources.make(device: device,
                                                                                      pixelFormat: .bgra8Unorm,
                                                                                      sampleCount: 4,
                                                                                      maxLatitude: WebMercatorMath.maxLatitudeRadians),
                                maxLatitude: WebMercatorMath.maxLatitudeRadians,
                                baseColors: ImmersiveMapBaseColors(map: SIMD4(0.09, 0.10, 0.13, 1),
                                                                   northCap: SIMD4(0.04, 0.09, 0.20, 1),
                                                                   southCap: SIMD4(0.30, 0.32, 0.36, 1)))
        tilePipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4, readsGroundShadowMask: true)
        extrudedPipeline = ExtrudedTilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        buildingIndexBuffers = HiddenBuildingIndexBuffers(device: device)
        surfaceLabelPipeline = SurfaceLabelPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        textRenderer = TextRenderer(device: device, resource: { _, _ in nil }, sampleCount: 4)
        horizon = HorizonRenderer(pipeline: HorizonPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4))
        starPipeline = StarfieldPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        modelPipeline = SceneModelPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        modelTilePipeline = ModelTilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        rasterPipeline = RasterTilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        fxaa = FXAAPipeline(device: device, pixelFormat: .bgra8Unorm)
        // The map draws the overlay in a pass of one sample, the probe in
        // its world pass of four.
        debugPolygons = PolygonsPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        debugOverlay = DebugOverlayRenderer(device: device)
        layerPipeline = LayerPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
    }

    /// The probe's sky: 64 stars on a spiral over the unit sphere, made with
    /// `+ - * /` and `sqrt` alone, which IEEE rounds the same everywhere.
    /// The engine's model (`StarfieldModel`) places its stars with `pow`,
    /// `sin` and `cos`, which Apple's and other C libraries round apart in
    /// the last bit, and the frame's stream is compared byte for byte
    /// across platforms (`WebGPUFrameStreamTests`).
    private static let starCount = 64

    private static func stars() -> [StarfieldStarVertex] {
        let count = starCount
        return (0 ..< count).map { index in
            let z = 1 - Float(2 * index + 1) / Float(count)
            let radial = (1 - z * z).squareRoot()
            // A point on the unit circle by its rational parametrisation,
            // the slope stepping through -2...2 in a scattered order.
            let t = Float((index * 37) % count) / 16 - 2
            let circle = SIMD2<Float>((1 - t * t) / (1 + t * t), 2 * t / (1 + t * t))
            return StarfieldStarVertex(position: SIMD3(radial * circle.x, radial * circle.y, z),
                                       size: 6 + Float(index % 5) * 3,
                                       brightness: 0.45 + Float(index % 7) / 12,
                                       temperature: Float(index % 11) / 10,
                                       twinklePhase: Float(index) / 8,
                                       halo: Float(index % 3) / 2)
        }
    }

    /// A scene model: a box from -1 to 1 on each axis in the models'
    /// interleaved layout (`SceneModelVertexLayout`), four corners a face
    /// wound counterclockwise seen from outside, untextured, in one
    /// submesh. It stands in for an asset the loader would read, which
    /// only Apple's platforms can.
    private static func model(device: any GPUDevice) -> SceneModelMesh? {
        // Each face by its normal and two tangents whose cross product is it.
        let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
        ]
        var vertices: [Float] = []
        var indices: [UInt16] = []
        for face in faces {
            let first = UInt16(vertices.count / 8)
            for (a, b) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                let position = face.normal + face.u * a + face.v * b
                vertices += [position.x, position.y, position.z,
                             face.normal.x, face.normal.y, face.normal.z,
                             (a + 1) / 2, (b + 1) / 2]
            }
            indices += [first, first + 1, first + 2, first, first + 2, first + 3]
        }
        assert(SceneModelVertexLayout.stride == 8 * MemoryLayout<Float>.stride)
        guard let vertexBuffer = device.makeBuffer(vertices, storage: .shared),
              let indexBuffer = device.makeBuffer(indices, storage: .shared) else { return nil }
        let submesh = SceneModelMesh.Submesh(topology: .triangle, indexCount: indices.count, indexType: .uint16,
                                             indexBuffer: indexBuffer, indexBufferOffset: 0)
        return SceneModelMesh(meshes: [SceneModelMesh.Part(vertexBuffer: vertexBuffer, vertexBufferOffset: 0, submeshes: [submesh])],
                              localTransforms: [matrix_identity_float4x4],
                              materials: [[SceneModelMesh.SubmeshMaterial(baseColorTexture: nil,
                                                                          baseColor: SIMD4(0.85, 0.55, 0.3, 1))]],
                              localBounds: SceneModelBounds(minimum: SIMD3(repeating: -1), maximum: SIMD3(repeating: 1)),
                              costInBytes: 0)
    }

    /// A model tile of the whole world: one tower in the tile's units, in
    /// the baker's vertex (`ModelTileContents`, version 6: a position is a
    /// place in the tile's bounding box, 0 to 65535 across it, and the
    /// draw takes it into tile space by `positionMatrix`), four corners a face wound
    /// counterclockwise seen from outside, the walls on the texture's first
    /// layer and the roof and floor on its second. The texture is RGBA, a
    /// format every backend samples, where an archive's is ASTC, which
    /// WebGPU offers only as an optional feature: the pipeline samples
    /// either alike.
    private static func modelTile(device: any GPUDevice) -> ModelTileMesh? {
        let low = SIMD3<Float>(600, 3000, 0), high = SIMD3<Float>(1000, 3400, 800)
        let center = (low + high) / 2, half = (high - low) / 2
        // Each face by its normal and two tangents whose cross product is it.
        let faces: [(normal: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
        ]
        var vertices: [UInt8] = []
        var indices: [UInt32] = []
        for face in faces {
            let first = UInt32(vertices.count / ModelTileContents.vertexStride)
            let layer: UInt8 = face.normal.z == 0 ? 0 : 1
            for (a, b) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
                let position = center + (face.normal + face.u * a + face.v * b) * half
                // The box is the tower's: a corner is 0 or 65535 on each axis.
                let stored = ((position - low) / (high - low) * Float(65535)).rounded(.toNearestOrAwayFromZero)
                for value in [stored.x, stored.y, stored.z] {
                    withUnsafeBytes(of: UInt16(value).littleEndian) { vertices += $0 }
                }
                withUnsafeBytes(of: (a < 0 ? UInt16.min : UInt16.max).littleEndian) { vertices += $0 }
                withUnsafeBytes(of: (b < 0 ? UInt16.max : UInt16.min).littleEndian) { vertices += $0 }
                vertices += [face.normal.x, face.normal.y, face.normal.z].map { UInt8(bitPattern: Int8($0 * 127)) }
                vertices.append(layer)
                vertices += [0, 0]
            }
            indices += [first, first + 1, first + 2, first, first + 2, first + 3]
        }
        assert(vertices.count == 24 * ModelTileContents.vertexStride)
        var descriptor = GPUTextureDescriptor(format: .rgba8Unorm, width: 2, height: 2)
        descriptor.type = .type2DArray
        descriptor.arrayLength = 2
        // Filled from the CPU below, which Metal allows only on shared storage.
        descriptor.storage = .shared
        guard let vertexBuffer = device.makeBuffer(vertices, storage: .shared),
              let indexBuffer = device.makeBuffer(indices, storage: .shared),
              let texture = device.makeTexture(descriptor) else { return nil }
        let layers: [[UInt8]] = [[200, 190, 170, 255, 180, 170, 150, 255, 180, 170, 150, 255, 200, 190, 170, 255],
                                 [90, 60, 50, 255, 90, 60, 50, 255, 90, 60, 50, 255, 90, 60, 50, 255]]
        for (slice, texels) in layers.enumerated() {
            texels.withUnsafeBytes { bytes in
                texture.replace(x: 0, y: 0, width: 2, height: 2, mipmapLevel: 0, slice: slice,
                                bytes: bytes.baseAddress!, bytesPerRow: 8)
            }
        }
        return ModelTileMesh(tile: Tile(x: 0, y: 0, z: 0),
                             indexCount: indices.count,
                             replacedBuildingIDs: [:],
                             boundsMinimum: low,
                             boundsMaximum: high,
                             // `ModelTileContents.positionMatrix` of these bounds.
                             positionMatrix: matrix_float4x4(columns: (SIMD4<Float>(high.x - low.x, 0, 0, 0),
                                                                       SIMD4<Float>(0, high.y - low.y, 0, 0),
                                                                       SIMD4<Float>(0, 0, high.z - low.z, 0),
                                                                       SIMD4<Float>(low.x, low.y, low.z, 1))),
                             vertexBuffer: vertexBuffer,
                             indexBuffer: indexBuffer,
                             texture: texture,
                             costInBytes: 0)
    }

    /// The raster tiles' sampler, as `RasterTileRenderSubsystem` makes it
    /// at the settings' default anisotropy.
    private static func rasterSampler(device: any GPUDevice) -> (any GPUSampler)? {
        var descriptor = GPUSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 4
        return device.makeSampler(descriptor)
    }

    /// A layer of the app's over the ground: a zone, a path across it and a
    /// point, a source's shapes drawn by a layer, by the public layer types
    /// and the mesh builder.
    private static func layer(device: any GPUDevice) -> LayerMesh? {
        let zone = ImmersiveMapPolygon(exterior: [GeoCoordinate(latitude: -40, longitude: -100),
                                                  GeoCoordinate(latitude: -40, longitude: -40),
                                                  GeoCoordinate(latitude: 20, longitude: -40),
                                                  GeoCoordinate(latitude: 20, longitude: -100)])
        let path = ImmersiveMapPolyline(coordinates: [GeoCoordinate(latitude: -50, longitude: 40),
                                                      GeoCoordinate(latitude: 0, longitude: 80),
                                                      GeoCoordinate(latitude: 50, longitude: 120)])
        let point = ImmersiveMapPoint(coordinate: GeoCoordinate(latitude: 50, longitude: -70))
        let layer = ImmersiveMapLayer(source: "probe")
        let content = LayerSourceContent(polygons: [zone], polylines: [path], points: [point])
        return LayerMesh(key: layer.meshKey(sourceRevision: 0),
                         data: LayerMeshBuilder.build(layer: layer, content: content),
                         device: device)
    }

    /// A label painted on the ground below the building: one glyph quad of
    /// two triangles, anchored on the tile in its units and offset in
    /// points, with a halo and a fill.
    private static func label(device: any GPUDevice, tile: Tile) -> SurfaceLabelDrawing.Item? {
        let anchor = SIMD2<Float>(2048, 1000)
        let corners: [(offset: SIMD2<Float>, uv: SIMD2<Float>)] = [
            (SIMD2(-40, -10), SIMD2(0, 1)), (SIMD2(40, -10), SIMD2(1, 1)), (SIMD2(40, 10), SIMD2(1, 0)),
            (SIMD2(-40, -10), SIMD2(0, 1)), (SIMD2(40, 10), SIMD2(1, 0)), (SIMD2(-40, 10), SIMD2(0, 0)),
        ]
        let vertices = corners.map { LabelVertex(position: anchor, uv: $0.uv, labelIndex: 0, spriteUV: $0.offset) }
        guard let buffer = device.makeBuffer(vertices, storage: .shared) else { return nil }
        let style = LabelTextStyle(key: 1, fillColor: SIMD3(0.95, 0.95, 0.9), strokeColor: SIMD3(0.1, 0.1, 0.1),
                                   haloEm: 0.15, sizePoints: 16, weight: .bold)
        let record = SurfaceLabelRecord(key: 1, style: style, placement: SurfaceLabelPlacement(referenceZoom: Double(tile.z)),
                                        vertexStart: 0, vertexCount: vertices.count)
        return SurfaceLabelDrawing.Item(tile: tile, worldWrap: 0, record: record,
                                        vertices: TileBufferView(gpuBuffer: buffer, offset: 0, count: vertices.count))
    }

    /// A box building in the middle of the tile: its lid and its four
    /// walls, wound clockwise seen from outside as the mesh builder winds
    /// them, with outward normals, in the tile's units.
    private static func building() -> (vertices: [ExtrudedVertexIn], indices: [UInt16]) {
        let low: Float = 1500, high: Float = 2600, height: Float = 600
        // The footprint clockwise seen from above (y up), as the mesh
        // builder forces the exterior ring.
        let ring: [SIMD2<Float>] = [SIMD2(low, low), SIMD2(low, high), SIMD2(high, high), SIMD2(high, low)]
        var vertices: [ExtrudedVertexIn] = []
        var indices: [UInt16] = []
        func quad(_ corners: [SIMD3<Float>], normal: SIMD3<Float>) {
            let base = UInt16(vertices.count)
            vertices += corners.map { ExtrudedVertexIn(position: $0, normal: normal, styleIndex: 0) }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        quad(ring.map { SIMD3($0, height) }, normal: SIMD3(0, 0, 1))
        for side in 0 ..< 4 {
            let a = ring[side], b = ring[(side + 1) % 4]
            let along = b - a
            let outward = simd_normalize(SIMD2(-along.y, along.x))
            quad([SIMD3(a, 0), SIMD3(a, height), SIMD3(b, height), SIMD3(b, 0)], normal: SIMD3(outward, 0))
        }
        return (vertices, indices)
    }

    /// A tile of the whole world in two triangles: an opaque fill, then the
    /// same square as line ribbons, and a building on it, each view at a
    /// multiple of 256 as a tile's spans are.
    private static func groundTile(device: any GPUDevice) -> PlaceTile? {
        guard let backing = device.makeBuffer(length: 2560, storage: .shared) else { return nil }
        let contents = backing.contents()
        let corners: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(4096, 0), SIMD2(4096, 4096), SIMD2(0, 4096)]
        for (index, corner) in corners.enumerated() {
            contents.storeBytes(of: TileVertexIn(position: corner, styleIndex: 0),
                                toByteOffset: index * MemoryLayout<TileVertexIn>.stride, as: TileVertexIn.self)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3, 0, 1, 2, 0, 2, 3]
        for (index, value) in indices.enumerated() {
            contents.storeBytes(of: value, toByteOffset: 256 + index * 2, as: UInt16.self)
        }
        contents.storeBytes(of: TilePolygonStyle(color: SIMD4(0.2, 0.5, 0.3, 1)), toByteOffset: 512, as: TilePolygonStyle.self)
        contents.storeBytes(of: SIMD2<Float>(0, 0), toByteOffset: 768, as: SIMD2<Float>.self)
        contents.storeBytes(of: TileLineStyle.polygon, toByteOffset: 1024, as: TileLineStyle.self)
        let ground = TileBuffers.GeometryLayer(
            vertices: TileBufferView(gpuBuffer: backing, offset: 0, count: corners.count),
            indices: TileBufferView(gpuBuffer: backing, offset: 256, count: indices.count),
            styles: TileBufferView(gpuBuffer: backing, offset: 512, count: 1),
            styleZoomFade: TileBufferView(gpuBuffer: backing, offset: 768, count: 1),
            lineStyles: TileBufferView(gpuBuffer: backing, offset: 1024, count: 1),
            indexType: .uint16,
            styleRuns: [GroundStyleRun(indexStart: 0, indexCount: 6, zoomFade: .zero, flags: GroundStyleRun.alphaOpaqueFlag),
                        GroundStyleRun(indexStart: 6, indexCount: 6, zoomFade: .zero,
                                       flags: GroundStyleRun.alphaOpaqueFlag | GroundStyleRun.linesClassFlag)])
        let building = Self.building()
        for (index, vertex) in building.vertices.enumerated() {
            contents.storeBytes(of: vertex, toByteOffset: 1280 + index * MemoryLayout<ExtrudedVertexIn>.stride, as: ExtrudedVertexIn.self)
        }
        for (index, value) in building.indices.enumerated() {
            contents.storeBytes(of: value, toByteOffset: 1536 + index * 2, as: UInt16.self)
        }
        contents.storeBytes(of: TilePolygonStyle(color: SIMD4(0.78, 0.74, 0.68, 1)), toByteOffset: 2048, as: TilePolygonStyle.self)
        let extruded = TileBuffers.Extruded(vertices: TileBufferView(gpuBuffer: backing, offset: 1280, count: building.vertices.count),
                                            indices: TileBufferView(gpuBuffer: backing, offset: 1536, count: building.indices.count),
                                            styles: TileBufferView(gpuBuffer: backing, offset: 2048, count: 1),
                                            gpuIndexType: .uint16)
        let empty = TileBuffers.GeometryLayer(vertices: nil, indices: nil, styles: nil, styleZoomFade: nil, lineStyles: nil, indexType: .uint16)
        let phases = RoadGeometryPhases(shadow: empty, casing: empty, fill: empty, detail: empty, overlay: empty)
        let buffers = TileBuffers(gpuBackingBuffer: backing,
                                  ground: ground,
                                  roads: RoadStructureBuckets(tunnel: phases, ground: phases, automobileGround: phases, bridge: phases),
                                  bridgeOverlay: empty,
                                  extruded: extruded,
                                  textLabels: TileBuffers.TextLabelSet(placementInputs: [], labelsByStyleRuns: [], poiIconRuns: []),
                                  roadLabels: TileBuffers.RoadLabels(pathInputs: [], pathRanges: [], pathLabels: [], labelStyle: nil,
                                                                     localGlyphVertices: nil, glyphBounds: [], glyphBoundRanges: [],
                                                                     sizes: [], anchorRanges: [], anchors: []))
        let tile = Tile(x: 0, y: 0, z: 0)
        return PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: buffers), placeIn: VisibleTile(tile: tile))
    }

    /// The world pass's multisampled targets for the size, and the texture
    /// its colour resolves into for the FXAA pass, made again when the size
    /// changes.
    private func worldTargets(width: Int, height: Int) -> (color: any GPUTexture, depth: any GPUTexture, scene: any GPUTexture)? {
        if let targets, targets.width == width, targets.height == height {
            return (targets.color, targets.depth, targets.scene)
        }
        var color = GPUTextureDescriptor(format: .bgra8Unorm, width: width, height: height)
        color.type = .type2DMultisample
        color.sampleCount = 4
        color.usage = .renderTarget
        var depth = GPUTextureDescriptor(format: .depth32FloatStencil8, width: width, height: height)
        depth.type = .type2DMultisample
        depth.sampleCount = 4
        depth.usage = .renderTarget
        var scene = GPUTextureDescriptor(format: .bgra8Unorm, width: width, height: height)
        scene.usage = [.shaderRead, .renderTarget]
        guard let colorTexture = device.makeTexture(color),
              let depthTexture = device.makeTexture(depth),
              let sceneTexture = device.makeTexture(scene) else { return nil }
        targets = (width, height, colorTexture, depthTexture, sceneTexture)
        return (colorTexture, depthTexture, sceneTexture)
    }

    /// Draws one frame into `target`, a `.bgra8Unorm` texture of the size,
    /// with the globe turned by `turn` (a turn of 1 is half the world), and
    /// commits it.
    package func drawFrame(into target: any GPUTexture, width: Int, height: Int, turn: Float) {
        guard let world = worldTargets(width: width, height: height),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        // The ground tile's fills into the raster tile's texture, before
        // the world pass, as `RasterTileRenderSubsystem.prepareGPU` draws a
        // tile whose texture must be drawn again.
        _ = RasterTileDrawer.bake([RasterTileDrawer.Bake(ground: tile.metalTile.tileBuffers.ground,
                                                         size: Self.rasterSize,
                                                         texture: rasterTexture)],
                                  atlas: rasterAtlas,
                                  commandBuffer: commandBuffer,
                                  pipeline: rasterPipeline,
                                  baseColor: SIMD4(0.09, 0.10, 0.13, 1),
                                  planningZoom: 15)
        var colorAttachment = GPUColorAttachment(texture: world.color)
        colorAttachment.resolveTexture = world.scene
        colorAttachment.store = .multisampleResolve
        colorAttachment.clearColor = GPUClearColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1)
        var pass = GPURenderPassDescriptor(colorAttachments: [colorAttachment],
                                           depthStencilAttachment: GPUDepthStencilAttachment(texture: world.depth))
        pass.label = "probe"
        guard let encoder = commandBuffer.makeRenderEncoder(pass) else { return }

        // An orthographic view: x and y scaled to the drawable's aspect, z
        // from -1...1 to the depth's 0...1.
        let aspect = Float(width) / Float(max(height, 1))
        let scale: Float = 0.9
        let camera = matrix_float4x4(columns: (SIMD4(scale / max(aspect, 1), 0, 0, 0),
                                               SIMD4(0, scale * min(aspect, 1), 0, 0),
                                               SIMD4(0, 0, -0.5, 0),
                                               SIMD4(0, 0, 0.5, 1)))
        let globe = GlobeUniform(panX: turn, panY: -0.2, radius: 0.7, transition: 0)
        // The stars first, the background at the far plane: the calls of
        // StarfieldRenderer.draw, with the probe's camera and no pan
        // rotation in place of its perspective and the pan's, which `tan`,
        // `sin` and `cos` make (see `stars()`).
        starPipeline.selectStarsPipeline(renderEncoder: encoder)
        encoder.setVertexBuffer(stars, offset: 0, index: 0)
        encoder.setVertexValue(CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0), index: 1)
        encoder.setVertexValue(globe, index: 2)
        encoder.setVertexValue(StarfieldParamsUniform(rotation: matrix_identity_float4x4, radiusScale: 1.25,
                                                      padding: SIMD3<Float>(repeating: 0)),
                               index: 3)
        encoder.setFragmentValue(turn, index: 0)
        if starPipeline.drawsQuads {
            encoder.setVertexValue(StarfieldQuadUniform(viewportSizePx: SIMD2(Float(width), Float(height))), index: 4)
            encoder.draw(.triangle, vertexStart: 0, vertexCount: 6, instanceCount: Self.starCount, baseInstance: 0)
        } else {
            encoder.draw(.point, vertexStart: 0, vertexCount: Self.starCount)
        }
        caps.draw(renderEncoder: encoder, globeFrame: GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: camera), globe: globe)
        // The raster texture on the tile's grid, first in the ground's
        // layer, placed as the vector ground's tile is.
        if let rasterMesh = rasterGrid.mesh(forTileZoom: 0) {
            let origin = ImmersiveMapProjection.flatTileOriginAndSize(x: 0, y: 0, z: 0, worldWrap: 0,
                                                                      flatRenderPan: .zero, renderMapSize: 1)
            let scale = origin.z / 4096
            RasterTileDrawer.drawFlat([RasterTileDrawer.FlatItem(texture: rasterTexture,
                                                                 stencilReference: TileSourceStencilPriority.reference(sourceZoom: 0),
                                                                 mesh: rasterMesh,
                                                                 modelMatrix: Matrix.translationMatrix(x: origin.x, y: origin.y, z: 0)
                                                                     * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1),
                                                                 relief: nil)],
                                      encoder: encoder,
                                      cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0),
                                      groundShadow: RasterTileDrawer.GroundShadow(uniform: .disabled, mask: mask, cascades: cascades),
                                      groundFog: .disabled,
                                      groundRelief: nil,
                                      renderMapSize: 1,
                                      sampling: RasterTileDrawer.Sampling(sampler: rasterSampler, mipLevelBias: 0, wireframe: false),
                                      pipeline: rasterPipeline,
                                      groundOwnerState: groundState,
                                      depthDisabledState: depthDisabledState)
        }
        for part in [FlatMapSurfaceDrawer.Part.ground, .roads] {
            FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                      cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0),
                                      cpuCameraMatrix: camera,
                                      cameraZoom: 15,
                                      pixelsPerPoint: 2,
                                      drawableSizePx: SIMD2(Float(width), Float(height)),
                                      placeTilesContext: PlaceTilesContext(tilePlacements: [tile]),
                                      flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 1),
                                      shadowUniform: .disabled,
                                      groundShadowMask: mask,
                                      shadowCascades: cascades,
                                      tilePipeline: tilePipeline,
                                      groundOwnerState: groundState,
                                      tileStencilTestState: groundState,
                                      roadRankState: groundState,
                                      part: part,
                                      isWireframeEnabled: false)
        }
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0),
                                              shadowUniform: .disabled,
                                              shadowMap: cascades,
                                              placeTilesContext: PlaceTilesContext(tilePlacements: [tile]),
                                              indexBuffers: buildingIndexBuffers,
                                              flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 1),
                                              extrudedTilePipeline: extrudedPipeline,
                                              extrudedStencilTestState: groundState,
                                              depthDisabledState: depthDisabledState)
        // The model beside the building, a sixteenth of the world across and
        // standing on the plane: a power of two, so its normal matrix (an
        // inverse) is exact on every platform.
        GroundFogUniform.bind(.disabled, encoder: encoder)
        let modelScale: Float = 1.0 / 32
        let modelMatrix = matrix_float4x4(columns: (SIMD4(modelScale, 0, 0, 0),
                                                    SIMD4(0, modelScale, 0, 0),
                                                    SIMD4(0, 0, modelScale, 0),
                                                    SIMD4(0.5, -0.5, modelScale, 1)))
        SceneModelDrawer.draw(renderEncoder: encoder,
                              cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0),
                              shadowUniform: .disabled,
                              shadowMap: cascades,
                              items: [SceneModelDrawItem(mesh: model,
                                                         modelMatrix: modelMatrix,
                                                         groundPlane: SceneModelGroundPlane(surfacePosition: SIMD3(0.5, -0.5, 0),
                                                                                            up: SIMD3(0, 0, 1)),
                                                         cutsIntoGround: false)],
                              pipeline: modelPipeline,
                              surfaceMaskState: groundState,
                              groundCutStates: SceneModelGroundCutStates(holeWrite: groundState, holeClear: groundState,
                                                                         holeTest: groundState),
                              depthDisabledState: depthDisabledState)
        // The model tile, placed as the map's buildings of its tile are
        // (`ModelTileRenderSubsystem.placement`): a translation and a
        // uniform scale, a power of two.
        let tileOrigin = ImmersiveMapProjection.flatTileOriginAndSize(x: 0, y: 0, z: 0, worldWrap: 0,
                                                                      flatRenderPan: .zero, renderMapSize: 1)
        let tileScale = tileOrigin.z / ModelTileContents.tileExtent
        ModelTileDrawer.draw(renderEncoder: encoder,
                             cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0),
                             shadowUniform: .disabled,
                             shadowMap: cascades,
                             items: [ModelTileDrawItem(mesh: modelTile,
                                                       modelMatrix: Matrix.translationMatrix(x: tileOrigin.x, y: tileOrigin.y, z: 0)
                                                           * Matrix.scaleMatrix(sx: tileScale, sy: tileScale, sz: tileScale))],
                             depthBias: 1.0 / 1024,
                             pipeline: modelTilePipeline,
                             surfaceMaskState: groundState,
                             depthDisabledState: depthDisabledState)
        let labelFrame = SurfaceLabelDrawing.Frame(cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0),
                                                   groundFog: .disabled,
                                                   tileScreenPoints: Double(min(width, height)) * 0.45,
                                                   viewportSizePx: SIMD2(Float(width), Float(height)),
                                                   pixelsPerPoint: 2,
                                                   labelOpacity: .solid,
                                                   surface: .flat(FlatRenderState(pan: .zero, renderMapSize: 1)))
        SurfaceLabelDrawing.draw([label], frame: labelFrame, pipeline: surfaceLabelPipeline, textRenderer: textRenderer,
                                 depthState: groundState, depthDisabledState: depthDisabledState, encoder: encoder)

        // The layer, its chunks placed on the plane as the layer subsystem
        // places them, after the frame's shared values it binds.
        let viewport = SIMD2<Float>(Float(width), Float(height))
        encoder.setVertexValue(CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0), index: 1)
        encoder.setVertexValue(globe, index: 8)
        encoder.setVertexValue(GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: camera), index: 10)
        GlobeLightUniform.bind(.disabled, encoder: encoder)
        GroundFogUniform.bind(.disabled, encoder: encoder)
        LayerDrawing.drawLayers([(layer, false)],
                                pipeline: layerPipeline,
                                surface: .flat,
                                placements: { chunk in
                                    let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: chunk.tile.x, y: chunk.tile.y,
                                                                                                     z: chunk.tile.z, worldWrap: 0,
                                                                                                     flatRenderPan: .zero,
                                                                                                     renderMapSize: 1)
                                    let scale = originAndSize.z / Float(TileCoordinateSpace.tileExtent)
                                    return [LayerDrawUniform(modelMatrix: Matrix.translationMatrix(x: originAndSize.x,
                                                                                                    y: originAndSize.y, z: 0)
                                                                 * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1),
                                                             uvOrigin: .zero,
                                                             uvScale: 0,
                                                             referenceWorldX: 0,
                                                             viewportSizePx: viewport,
                                                             pixelsPerPoint: 2,
                                                             depth: LayerDepth.depth)]
                                },
                                depthDisabledState: depthDisabledState,
                                encoder: encoder)

        // The debug overlay's axes, from the origin along x, y and z.
        debugOverlay.drawAxes(renderEncoder: encoder,
                              polygonPipeline: debugPolygons,
                              cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0))

        // The horizon's sky side over what nothing painted, its band about
        // the view's vertical, the edge a little below it.
        encoder.setDepthStencilState(groundState)
        horizon.draw(renderEncoder: encoder,
                     uniform: HorizonUniform(up: SIMD3(0, 1, 0), depression: 0.05,
                                             center: SIMD3(0, 0, -1), sunInfluence: 0,
                                             light: SIMD3(0, 0, 1), skyStrength: 0.6,
                                             tint: SIMD3(0.55, 0.7, 0.95), whitenWeight: 0.3,
                                             eye: SIMD3(0, 0, 3), featherStrength: 0.4,
                                             bandRadians: 0.05, glowRadians: 0.3, whitenRadians: 0.02,
                                             featherRadians: 0.005, groundBandRadians: 0.05, groundGain: 1,
                                             cutoffStartRadians: 0.2, cutoffEndRadians: 0.3,
                                             skyColor: SIMD3(0.2, 0.35, 0.6), skyOpacity: 0,
                                             skyGradientRadians: 0.2,
                                             viewProjection: camera,
                                             bandTopRadians: 0.6),
                     groundSide: false)
        encoder.setDepthStencilState(depthDisabledState)
        encoder.endEncoding()

        // The FXAA pass: the resolved frame, smoothed into the target.
        var post = GPURenderPassDescriptor(colorAttachments: [GPUColorAttachment(texture: target)])
        post.label = "postProcessing"
        guard let postEncoder = commandBuffer.makeRenderEncoder(post) else { return }
        fxaa.draw(renderEncoder: postEncoder, sourceTexture: world.scene, width: Float(width), height: Float(height))
        postEncoder.endEncoding()
        commandBuffer.commit()
    }
}
