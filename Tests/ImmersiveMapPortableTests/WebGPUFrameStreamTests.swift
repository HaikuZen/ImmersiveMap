// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import ImmersiveMapGPU
import ImmersiveMapWebGPU
import simd
import XCTest
@testable import ImmersiveMap

/// A frame of moved features drawn through the WebGPU backend, its stream
/// held to `Web/test/frames/`, which `node Tools/WGSLCheck/frames.mjs` runs on
/// Dawn and fails on any WebGPU validation error: the pipelines, their
/// variants, the bindings the reflection finds and the placeholders, as a
/// browser would meet them. No picture. A change to what the features ask
/// of the GPU fails here: run this test once with
/// `IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES=1` to write the streams anew, then the
/// Node run.
final class WebGPUFrameStreamTests: XCTestCase {
    private final class Sink: WebGPUCommandSink, @unchecked Sendable {
        var stream: [UInt8] = []

        func submit(_ bytes: UnsafeRawBufferPointer) {
            stream.append(contentsOf: bytes)
        }
    }

    private static let framesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Web/test/frames")

    /// A square tile of two triangles: an opaque fill, then the same square
    /// as line ribbons, each view at a multiple of 256 as a tile's spans are.
    private func groundTile(device: WebGPUDevice) throws -> PlaceTile {
        let backing = try XCTUnwrap(device.makeBuffer(length: 2048, storage: .shared))
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
            vertices: TileBufferView(gpuBuffer: backing, offset: 0, count: 4),
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
        let tile = Tile(x: 0, y: 0, z: 15)
        return PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: buffers), placeIn: VisibleTile(tile: tile))
    }

    private static func depthState(device: WebGPUDevice, writes: Bool, stencil: Bool) throws -> any GPUDepthStencilState {
        var descriptor = GPUDepthStencilDescriptor()
        descriptor.depthCompare = .lessEqual
        descriptor.depthWriteEnabled = writes
        if stencil {
            var face = GPUStencilFaceState()
            face.compare = .equal
            descriptor.frontStencil = face
            descriptor.backStencil = face
        }
        return try XCTUnwrap(device.makeDepthStencilState(descriptor))
    }

    /// The globe's caps and the flat ground's fills and ribbons, into the
    /// world pass's targets: multisampled colour resolved into the canvas,
    /// and the depth and stencil.
    private func groundAndCapsStream() throws -> [UInt8] {
        let sink = Sink()
        let device = WebGPUDevice(features: [.depthClamp], sink: sink)
        let size = (width: 64, height: 64)
        var color = GPUTextureDescriptor(format: .bgra8Unorm, width: size.width, height: size.height)
        color.type = .type2DMultisample
        color.sampleCount = 4
        color.usage = .renderTarget
        var depth = GPUTextureDescriptor(format: .depth32FloatStencil8, width: size.width, height: size.height)
        depth.type = .type2DMultisample
        depth.sampleCount = 4
        depth.usage = .renderTarget
        let colorTexture = try XCTUnwrap(device.makeTexture(color))
        let depthTexture = try XCTUnwrap(device.makeTexture(depth))
        let mask = try XCTUnwrap(device.makeTexture(GPUTextureDescriptor(format: GroundShadowMaskPipeline.format, width: 8, height: 8)))
        var cascadesDescriptor = GPUTextureDescriptor(format: ShadowCascadeAtlas.depthFormat, width: 8, height: 8)
        cascadesDescriptor.type = .type2DArray
        cascadesDescriptor.arrayLength = ShadowCascadeAtlas.sliceCount
        cascadesDescriptor.usage = [.shaderRead, .renderTarget]
        let cascades = try XCTUnwrap(device.makeTexture(cascadesDescriptor))

        let caps = GlobeCapRenderer(sharedResources: GlobeCapRenderer.SharedResources.make(device: device,
                                                                                          pixelFormat: .bgra8Unorm,
                                                                                          sampleCount: 4,
                                                                                          maxLatitude: WebMercatorMath.maxLatitudeRadians),
                                    maxLatitude: WebMercatorMath.maxLatitudeRadians,
                                    baseColors: ImmersiveMapBaseColors(map: SIMD4(0.09, 0.10, 0.13, 1),
                                                                       northCap: SIMD4(0.04, 0.09, 0.20, 1),
                                                                       southCap: SIMD4(0.30, 0.32, 0.36, 1)))
        let tilePipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4, readsGroundShadowMask: true)
        let owner = try Self.depthState(device: device, writes: true, stencil: true)
        let test = try Self.depthState(device: device, writes: false, stencil: true)
        let roadRank = try Self.depthState(device: device, writes: true, stencil: true)
        let tile = try groundTile(device: device)

        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        var colorAttachment = GPUColorAttachment(texture: colorTexture)
        colorAttachment.resolveTexture = device.canvasTexture(format: .bgra8Unorm, width: size.width, height: size.height)
        colorAttachment.store = .multisampleResolve
        var pass = GPURenderPassDescriptor(colorAttachments: [colorAttachment],
                                           depthStencilAttachment: GPUDepthStencilAttachment(texture: depthTexture))
        pass.label = "world"
        let encoder = try XCTUnwrap(commandBuffer.makeRenderEncoder(pass))

        let globe = GlobeUniform(panX: 0.1, panY: -0.2, radius: 0.7, transition: 0)
        let camera = matrix_identity_float4x4
        caps.draw(renderEncoder: encoder, globeFrame: GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: camera), globe: globe)
        for part in [FlatMapSurfaceDrawer.Part.ground, .roads] {
            FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                      cameraUniform: CameraUniform(matrix: camera, eye: SIMD3(0, 0, 3), padding: 0),
                                      cpuCameraMatrix: camera,
                                      cameraZoom: 15,
                                      pixelsPerPoint: 2,
                                      drawableSizePx: SIMD2(Float(size.width), Float(size.height)),
                                      placeTilesContext: PlaceTilesContext(tilePlacements: [tile]),
                                      flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                                      shadowUniform: .disabled,
                                      groundShadowMask: mask,
                                      shadowCascades: cascades,
                                      tilePipeline: tilePipeline,
                                      groundOwnerState: owner,
                                      tileStencilTestState: test,
                                      roadRankState: roadRank,
                                      part: part,
                                      isWireframeEnabled: false)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        withExtendedLifetime((colorTexture, depthTexture, mask, cascades, caps, tilePipeline, owner, test, roadRank, tile)) {}
        return sink.stream
    }

    func testTheFramesAreTheStreamsTheEngineWrites() throws {
        let frames = ["ground-and-caps.bin": try groundAndCapsStream()]
        if ProcessInfo.processInfo.environment["IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES"] == "1" {
            try FileManager.default.createDirectory(at: Self.framesURL, withIntermediateDirectories: true)
            for (name, stream) in frames {
                try Data(stream).write(to: Self.framesURL.appendingPathComponent(name))
            }
            return
        }
        for (name, stream) in frames {
            let committed = try XCTUnwrap(FileManager.default.contents(atPath: Self.framesURL.appendingPathComponent(name).path),
                                          "No \(name): write it with IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES=1")
            XCTAssertEqual(Array(committed), stream,
                           "\(name) changed: write it anew with IMMERSIVE_MAP_WRITE_WEBGPU_FRAMES=1, then run node Tools/WGSLCheck/frames.mjs")
        }
    }
}
