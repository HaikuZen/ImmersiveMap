// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the flat ground asks of the GPU, recorded: the opaque and the
/// translucent fills with the states that own and test the priority
/// stencil, a source placed twice drawn once, the line ribbons and the
/// roads with their edge lines, and the shadow it reads. No picture: the
/// ground is judged in the app.
final class FlatMapSurfaceDrawTests: XCTestCase {
    /// One draw as the encoder's state stood when it was made.
    private struct Draw: Equatable {
        let pipeline: String?
        let state: GPUDepthStencilDescriptor?
        let topology: GPUPrimitiveTopology
        let count: Int
        let offset: Int
    }

    private struct Fixture {
        let device = RecordingGPUDevice()
        let pipeline: TilePipeline
        let owner: any GPUDepthStencilState
        let test: any GPUDepthStencilState
        let roadRank: any GPUDepthStencilState
        let mask: any GPUTexture
        let cascades: any GPUTexture
        let backing: any GPUBuffer

        init() throws {
            pipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4, readsGroundShadowMask: true)
            owner = try XCTUnwrap(device.makeDepthStencilState(Self.state(.lessEqual, writes: true)))
            test = try XCTUnwrap(device.makeDepthStencilState(Self.state(.lessEqual, writes: false)))
            roadRank = try XCTUnwrap(device.makeDepthStencilState(Self.state(.greater, writes: true)))
            mask = try XCTUnwrap(device.makeTexture(GPUTextureDescriptor(format: GroundShadowMaskPipeline.format, width: 8, height: 8)))
            cascades = try XCTUnwrap(device.makeTexture(GPUTextureDescriptor(format: ShadowCascadeAtlas.depthFormat, width: 8, height: 8)))
            backing = try XCTUnwrap(device.makeBuffer(length: 4096, storage: .shared))
        }

        static func state(_ compare: GPUCompareFunction, writes: Bool) -> GPUDepthStencilDescriptor {
            var descriptor = GPUDepthStencilDescriptor()
            descriptor.depthCompare = compare
            descriptor.depthWriteEnabled = writes
            return descriptor
        }

        /// A layer of `indexCount` 16-bit indices at `indexOffset` of the
        /// backing buffer, over one shared set of vertices and styles, each
        /// view at a multiple of 256 as a tile's spans are.
        func layer(indexOffset: Int,
                   indexCount: Int,
                   styleRuns: [GroundStyleRun] = [],
                   roadStyles: RoadLayerStyles = .empty,
                   roadEdgeLineIndexStart: Int? = nil) -> TileBuffers.GeometryLayer {
            TileBuffers.GeometryLayer(vertices: TileBufferView(gpuBuffer: backing, offset: 0, count: 4),
                                      indices: TileBufferView(gpuBuffer: backing, offset: indexOffset, count: indexCount),
                                      styles: TileBufferView(gpuBuffer: backing, offset: 1024, count: 1),
                                      styleZoomFade: TileBufferView(gpuBuffer: backing, offset: 1280, count: 1),
                                      lineStyles: TileBufferView(gpuBuffer: backing, offset: 1536, count: 1),
                                      indexType: .uint16,
                                      styleRuns: styleRuns,
                                      roadStyles: roadStyles,
                                      roadEdgeLineIndexStart: roadEdgeLineIndexStart)
        }

        /// `tile` with `ground` and, in the ground bucket's fill, `road`.
        func placement(_ tile: Tile,
                       ground: TileBuffers.GeometryLayer,
                       road: TileBuffers.GeometryLayer? = nil,
                       worldWrap: Int8 = 0) -> PlaceTile {
            let empty = TestTiles.emptyLayer()
            let none = RoadGeometryPhases(shadow: empty, casing: empty, fill: empty, detail: empty, overlay: empty)
            let groundRoads = RoadGeometryPhases(shadow: empty, casing: empty, fill: road ?? empty, detail: empty, overlay: empty)
            var buffers = TestTiles.buffers(backing: backing)
            buffers = TileBuffers(gpuBackingBuffer: backing,
                                  ground: ground,
                                  roads: RoadStructureBuckets(tunnel: none, ground: groundRoads, automobileGround: none, bridge: none),
                                  bridgeOverlay: empty,
                                  extruded: buffers.extruded,
                                  textLabels: buffers.textLabels,
                                  roadLabels: buffers.roadLabels)
            return PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: buffers),
                             placeIn: VisibleTile(tile: tile, worldWrap: worldWrap))
        }

        func draw(_ placements: [PlaceTile],
                  part: FlatMapSurfaceDrawer.Part,
                  shadow: ShadowUniform = .disabled,
                  wireframe: Bool = false) -> RecordingRenderEncoder {
            let encoder = RecordingRenderEncoder()
            FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                      cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: SIMD3(0, 0, 3), padding: 0),
                                      cpuCameraMatrix: matrix_identity_float4x4,
                                      cameraZoom: 15,
                                      pixelsPerPoint: 2,
                                      drawableSizePx: SIMD2(800, 600),
                                      placeTilesContext: PlaceTilesContext(tilePlacements: placements),
                                      flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                                      shadowUniform: shadow,
                                      groundShadowMask: mask,
                                      shadowCascades: cascades,
                                      tilePipeline: pipeline,
                                      groundOwnerState: owner,
                                      tileStencilTestState: test,
                                      roadRankState: roadRank,
                                      part: part,
                                      isWireframeEnabled: wireframe)
            return encoder
        }
    }

    private static func run(_ start: UInt32, _ count: UInt32, fadeFrom: Float = 0, flags: UInt32) -> GroundStyleRun {
        GroundStyleRun(indexStart: start, indexCount: count, zoomFade: SIMD2(fadeFrom, fadeFrom), flags: flags)
    }

    /// Four runs of 6 indices: an opaque fill, a translucent fill, a fill
    /// faded out at zoom 15, and line ribbons.
    private static let groundRuns = [
        run(0, 6, flags: GroundStyleRun.alphaOpaqueFlag),
        run(6, 6, flags: 0),
        run(12, 6, fadeFrom: 20, flags: GroundStyleRun.alphaOpaqueFlag),
        run(18, 6, flags: GroundStyleRun.linesClassFlag | GroundStyleRun.alphaOpaqueFlag),
    ]

    private func draws(_ encoder: RecordingRenderEncoder) -> [Draw] {
        var pipeline: String?
        var state: GPUDepthStencilDescriptor?
        var draws: [Draw] = []
        for command in encoder.commands {
            switch command {
            case let .setPipeline(descriptor): pipeline = descriptor.label
            case let .setDepthStencilState(descriptor): state = descriptor
            case let .drawIndexed(topology, count, _, _, offset, _, _, _):
                draws.append(Draw(pipeline: pipeline, state: state, topology: topology, count: count, offset: offset))
            default: break
            }
        }
        return draws
    }

    func testTheGroundDrawsItsOpaqueFillsOwningTheStencilThenItsTranslucentFills() throws {
        let fixture = try Fixture()
        let tile = Tile(x: 9904, y: 5121, z: 15)
        let ground = fixture.layer(indexOffset: 256, indexCount: 24, styleRuns: Self.groundRuns)
        // The same source in two slots, as a target and as a stand-in.
        let placements = [fixture.placement(tile, ground: ground), fixture.placement(tile, ground: ground)]
        var shadow = ShadowUniform.disabled
        shadow.strength = 0.4
        let encoder = fixture.draw(placements, part: .ground, shadow: shadow)

        let owner = Fixture.state(.lessEqual, writes: true)
        let test = Fixture.state(.lessEqual, writes: false)
        XCTAssertEqual(draws(encoder), [
            Draw(pipeline: "TileOpaqueFills", state: owner, topology: .triangle, count: 6, offset: 256),
            Draw(pipeline: "TileFills", state: test, topology: .triangle, count: 6, offset: 256 + 6 * 2),
        ], "Once for the source, the faded fill and the ribbons left out")
        XCTAssertEqual(Array(encoder.commands.prefix(3)), [.setPipeline(try XCTUnwrap((fixture.pipeline.pipelineState as? RecordingRenderPipeline)?.descriptor)),
                                                          .setFrontFacing(.counterClockwise),
                                                          .setCullMode(.back)])
        XCTAssertEqual(Array(encoder.commands.suffix(2)), [.setCullMode(.none), .setFrontFacing(.clockwise)],
                       "Leaves the shared encoder's winding and culling as Metal's default")
        XCTAssertTrue(encoder.commands.contains(.setStencilReference(TileSourceStencilPriority.reference(sourceZoom: 15))))
        XCTAssertTrue(encoder.commands.contains(.setFragmentTexture((fixture.mask as! RecordingTexture).name, index: 1)))
        XCTAssertTrue(encoder.commands.contains(.setFragmentTexture((fixture.cascades as! RecordingTexture).name, index: 0)))
        XCTAssertEqual(encoder.fragmentValue(at: 3, as: ShadowUniform.self)?.strength, 0.4)
        let backing = try XCTUnwrap(fixture.backing as? RecordingBuffer).name
        XCTAssertTrue(encoder.commands.contains(.setVertexBuffer(backing, offset: 1024, index: 2)), "The styles at their span")
        XCTAssertTrue(encoder.commands.contains(.setFragmentBuffer(backing, offset: 1536, index: 7)), "The line styles at their span")
        XCTAssertEqual(encoder.vertexValue(at: 7, as: FlatDepthBand.self)?.offset, 0)
        XCTAssertEqual(encoder.vertexValue(at: 8, as: TileOverviewFadeUniform.self)?.cameraZoom, 15)
    }

    func testEachWrapCopyOfASourceDrawsItsOwnGround() throws {
        let fixture = try Fixture()
        let tile = Tile(x: 0, y: 0, z: 15)
        let ground = fixture.layer(indexOffset: 256, indexCount: 6, styleRuns: [Self.run(0, 6, flags: GroundStyleRun.alphaOpaqueFlag)])
        let encoder = fixture.draw([fixture.placement(tile, ground: ground),
                                    fixture.placement(tile, ground: ground, worldWrap: 1)],
                                   part: .ground)
        XCTAssertEqual(draws(encoder).count, 2)
        let models = encoder.commands.compactMap { command -> matrix_float4x4? in
            guard case let .setVertexBytes(bytes, 3) = command else { return nil }
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: matrix_float4x4.self) }
        }
        XCTAssertEqual(models.count, 2)
        XCTAssertNotEqual(models[0].columns.3.x, models[1].columns.3.x, "One world apart")
    }

    func testWhatLiesOnTheGroundDrawsItsRibbonsThenItsRoadsAndTheirEdgeLines() throws {
        let fixture = try Fixture()
        let tile = Tile(x: 9904, y: 5121, z: 15)
        let ground = fixture.layer(indexOffset: 256, indexCount: 24, styleRuns: Self.groundRuns)
        let opaqueRoad = RoadLayerStyles(styles: [RoadLayerStyles.Style(isAlphaOpaque: true, zoomFade: .zero,
                                                                        rampStartAlpha: 1, rampStartZoom: 0, rampEndZoom: 0,
                                                                        isDashed: false)])
        // 12 indices: 6 of road bodies, then 6 of edge lines.
        let road = fixture.layer(indexOffset: 512, indexCount: 12, roadStyles: opaqueRoad, roadEdgeLineIndexStart: 6)
        let encoder = fixture.draw([fixture.placement(tile, ground: ground, road: road)], part: .roads, wireframe: true)

        let test = Fixture.state(.lessEqual, writes: false)
        let rank = Fixture.state(.greater, writes: true)
        XCTAssertEqual(draws(encoder), [
            Draw(pipeline: "TileLines", state: test, topology: .triangle, count: 6, offset: 256 + 18 * 2),
            Draw(pipeline: "TileRoadOpaque", state: rank, topology: .triangle, count: 6, offset: 512),
            Draw(pipeline: "TileRoadBlended", state: test, topology: .line, count: 6, offset: 512 + 6 * 2),
        ], "The ribbons alone of the ground, the road's bodies opaque, its edge lines blended")
        XCTAssertEqual(encoder.fragmentValue(at: 11, as: Float.self), FlatMapSurfaceDrawer.roadEdgeLineAlpha)
        let band = RoadRankDepth.band(structureKind: .ground, role: .fill)
        XCTAssertEqual(encoder.vertexValue(at: 7, as: FlatDepthBand.self)?.offset, RoadRankDepth.depthOffset(band: band))
        XCTAssertTrue(encoder.commands.contains(.setTriangleFillMode(.lines)))
        XCTAssertEqual(Array(encoder.commands.suffix(3)), [.setTriangleFillMode(.fill), .setCullMode(.none), .setFrontFacing(.clockwise)],
                       "Back to filled triangles")
    }
}
