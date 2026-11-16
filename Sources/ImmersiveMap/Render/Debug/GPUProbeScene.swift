// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import simd

/// A small scene of features already moved onto the GPU interface, drawn
/// through any backend: the globe's polar caps turning over a square of
/// flat ground with its fills and its line ribbons, into the world pass's
/// targets (multisampled colour resolved into the frame's target, depth
/// and stencil). It is not the map: it is what a new backend is proven
/// with before the render core runs on it. `WebGPUFrameStreamTests` holds
/// its WebGPU stream, and the browser probe (`ImmersiveMapWebProbe`,
/// `Web/probe/`) draws it every frame.
package final class GPUProbeScene {
    private let device: any GPUDevice
    private let queue: any GPUCommandQueue
    private let caps: GlobeCapRenderer
    private let tilePipeline: TilePipeline
    private let groundState: any GPUDepthStencilState
    private let mask: any GPUTexture
    private let cascades: any GPUTexture
    private let tile: PlaceTile
    private var targets: (width: Int, height: Int, color: any GPUTexture, depth: any GPUTexture)?

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
              let tile = Self.groundTile(device: device) else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.mask = mask
        self.cascades = cascades
        self.groundState = groundState
        self.tile = tile
        caps = GlobeCapRenderer(sharedResources: GlobeCapRenderer.SharedResources.make(device: device,
                                                                                      pixelFormat: .bgra8Unorm,
                                                                                      sampleCount: 4,
                                                                                      maxLatitude: WebMercatorMath.maxLatitudeRadians),
                                maxLatitude: WebMercatorMath.maxLatitudeRadians,
                                baseColors: ImmersiveMapBaseColors(map: SIMD4(0.09, 0.10, 0.13, 1),
                                                                   northCap: SIMD4(0.04, 0.09, 0.20, 1),
                                                                   southCap: SIMD4(0.30, 0.32, 0.36, 1)))
        tilePipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4, readsGroundShadowMask: true)
    }

    /// A tile of the whole world in two triangles: an opaque fill, then the
    /// same square as line ribbons, each view at a multiple of 256 as a
    /// tile's spans are.
    private static func groundTile(device: any GPUDevice) -> PlaceTile? {
        guard let backing = device.makeBuffer(length: 2048, storage: .shared) else { return nil }
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
        let empty = TileBuffers.GeometryLayer(vertices: nil, indices: nil, styles: nil, styleZoomFade: nil, lineStyles: nil, indexType: .uint16)
        let phases = RoadGeometryPhases(shadow: empty, casing: empty, fill: empty, detail: empty, overlay: empty)
        let buffers = TileBuffers(gpuBackingBuffer: backing,
                                  ground: ground,
                                  roads: RoadStructureBuckets(tunnel: phases, ground: phases, automobileGround: phases, bridge: phases),
                                  bridgeOverlay: empty,
                                  extruded: TileBuffers.Extruded(vertices: nil, indices: nil, styles: nil, gpuIndexType: .uint16),
                                  textLabels: TileBuffers.TextLabelSet(placementInputs: [], labelsByStyleRuns: [], poiIconRuns: []),
                                  roadLabels: TileBuffers.RoadLabels(pathInputs: [], pathRanges: [], pathLabels: [], labelStyle: nil,
                                                                     localGlyphVertices: nil, glyphBounds: [], glyphBoundRanges: [],
                                                                     sizes: [], anchorRanges: [], anchors: []))
        let tile = Tile(x: 0, y: 0, z: 0)
        return PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: buffers), placeIn: VisibleTile(tile: tile))
    }

    /// The world pass's multisampled targets for the size, made again when
    /// it changes.
    private func worldTargets(width: Int, height: Int) -> (color: any GPUTexture, depth: any GPUTexture)? {
        if let targets, targets.width == width, targets.height == height {
            return (targets.color, targets.depth)
        }
        var color = GPUTextureDescriptor(format: .bgra8Unorm, width: width, height: height)
        color.type = .type2DMultisample
        color.sampleCount = 4
        color.usage = .renderTarget
        var depth = GPUTextureDescriptor(format: .depth32FloatStencil8, width: width, height: height)
        depth.type = .type2DMultisample
        depth.sampleCount = 4
        depth.usage = .renderTarget
        guard let colorTexture = device.makeTexture(color), let depthTexture = device.makeTexture(depth) else { return nil }
        targets = (width, height, colorTexture, depthTexture)
        return (colorTexture, depthTexture)
    }

    /// Draws one frame into `target`, a `.bgra8Unorm` texture of the size,
    /// with the globe turned by `turn` (a turn of 1 is half the world), and
    /// commits it.
    package func drawFrame(into target: any GPUTexture, width: Int, height: Int, turn: Float) {
        guard let world = worldTargets(width: width, height: height),
              let commandBuffer = queue.makeCommandBuffer() else { return }
        var colorAttachment = GPUColorAttachment(texture: world.color)
        colorAttachment.resolveTexture = target
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
        caps.draw(renderEncoder: encoder, globeFrame: GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: camera), globe: globe)
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
        encoder.endEncoding()
        commandBuffer.commit()
    }
}
