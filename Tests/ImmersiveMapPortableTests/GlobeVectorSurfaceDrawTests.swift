// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the globe's ground asks of the GPU, recorded: the opaque fills,
/// the translucent fills and the ribbons as class passes, merged runs, a
/// source placed twice drawn once, the veiled ribbons' two phases, the
/// morph's variants, and a raster placement's lines alone. No picture: the
/// globe is judged in the app.
final class GlobeVectorSurfaceDrawTests: XCTestCase {
    /// One draw as the encoder's state stood when it was made.
    private struct Draw: Equatable {
        let pipeline: String?
        let state: GPUDepthStencilDescriptor?
        let count: Int
        let offset: Int
    }

    private struct Fixture {
        let device = RecordingGPUDevice()
        let pipeline: TilePipeline
        let opaque: any GPUDepthStencilState
        let ribbonOwner: any GPUDepthStencilState
        let translucent: any GPUDepthStencilState
        let disabled: any GPUDepthStencilState
        let backing: any GPUBuffer

        init() throws {
            pipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4, surface: .sphere)
            opaque = try XCTUnwrap(device.makeDepthStencilState(Self.state(.lessEqual, writes: true)))
            ribbonOwner = try XCTUnwrap(device.makeDepthStencilState(Self.state(.less, writes: true)))
            translucent = try XCTUnwrap(device.makeDepthStencilState(Self.state(.lessEqual, writes: false)))
            disabled = try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor()))
            backing = try XCTUnwrap(device.makeBuffer(length: 4096, storage: .shared))
        }

        static func state(_ compare: GPUCompareFunction, writes: Bool) -> GPUDepthStencilDescriptor {
            var descriptor = GPUDepthStencilDescriptor()
            descriptor.depthCompare = compare
            descriptor.depthWriteEnabled = writes
            return descriptor
        }

        /// `tile` whose ground is 16-bit indices at 256 of the backing
        /// buffer, in `runs`, each view at a multiple of 256 as a tile's
        /// spans are.
        func placement(_ tile: Tile, runs: [GroundStyleRun], rules: TileDrawRules = .all) -> PlaceTile {
            let indexCount = runs.map { Int($0.indexStart + $0.indexCount) }.max() ?? 0
            let ground = TileBuffers.GeometryLayer(vertices: TileBufferView(gpuBuffer: backing, offset: 0, count: 4),
                                                   indices: TileBufferView(gpuBuffer: backing, offset: 256, count: indexCount),
                                                   styles: TileBufferView(gpuBuffer: backing, offset: 1024, count: 1),
                                                   styleZoomFade: TileBufferView(gpuBuffer: backing, offset: 1280, count: 1),
                                                   lineStyles: TileBufferView(gpuBuffer: backing, offset: 1536, count: 1),
                                                   indexType: .uint16,
                                                   styleRuns: runs)
            let buffers = TestTiles.buffers(backing: backing)
            let tileBuffers = TileBuffers(gpuBackingBuffer: backing,
                                          ground: ground,
                                          roads: buffers.roads,
                                          bridgeOverlay: buffers.bridgeOverlay,
                                          extruded: buffers.extruded,
                                          textLabels: buffers.textLabels,
                                          roadLabels: buffers.roadLabels)
            return PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: tileBuffers),
                             placeIn: VisibleTile(tile: tile),
                             rules: rules)
        }

        func draw(_ placements: [PlaceTile], pureSphere: Bool = true) -> RecordingRenderEncoder {
            let encoder = RecordingRenderEncoder()
            let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: pureSphere ? 0 : 0.5)
            GlobeVectorSurfaceDrawer.draw(renderEncoder: encoder,
                                          cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: SIMD3(0, 0, 3), padding: 0),
                                          globe: globe,
                                          cameraZoom: 5,
                                          pixelsPerPoint: 2,
                                          drawableHeightPx: 600,
                                          renderMapSize: 4,
                                          placeTilesContext: PlaceTilesContext(tilePlacements: placements),
                                          pipeline: pipeline,
                                          opaqueDepthState: opaque,
                                          ribbonOwnerDepthState: ribbonOwner,
                                          translucentDepthState: translucent,
                                          depthDisabledState: disabled,
                                          isWireframeEnabled: false,
                                          pureSphere: pureSphere,
                                          globeFrame: GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: matrix_identity_float4x4),
                                          handoverUniform: TileSphereHandoverUniform(handover: 0.25))
            return encoder
        }
    }

    private static func run(_ start: UInt32, _ count: UInt32, fadeFrom: Float = 0, flags: UInt32) -> GroundStyleRun {
        GroundStyleRun(indexStart: start, indexCount: count, zoomFade: SIMD2(fadeFrom, fadeFrom), flags: flags)
    }

    private static let opaqueFill = GroundStyleRun.alphaOpaqueFlag
    private static let ribbon = GroundStyleRun.linesClassFlag | GroundStyleRun.alphaOpaqueFlag

    private func draws(_ encoder: RecordingRenderEncoder) -> [Draw] {
        var pipeline: String?
        var state: GPUDepthStencilDescriptor?
        var draws: [Draw] = []
        for command in encoder.commands {
            switch command {
            case let .setPipeline(descriptor): pipeline = descriptor.label
            case let .setDepthStencilState(descriptor): state = descriptor
            case let .drawIndexed(_, count, _, _, offset, _, _, _):
                draws.append(Draw(pipeline: pipeline, state: state, count: count, offset: offset))
            default: break
            }
        }
        return draws
    }

    func testTheRestingSphereDrawsItsClassesInTurnAndEachSourceOnce() throws {
        let fixture = try Fixture()
        let tile = Tile(x: 9, y: 5, z: 5)
        // Two adjacent opaque fills, a translucent fill, a fill faded out
        // at zoom 5, and ribbons.
        let runs = [Self.run(0, 6, flags: Self.opaqueFill),
                    Self.run(6, 6, flags: Self.opaqueFill),
                    Self.run(12, 6, flags: 0),
                    Self.run(18, 6, fadeFrom: 9, flags: 0),
                    Self.run(24, 6, flags: Self.ribbon)]
        // The same source in two slots, as a target and as a stand-in.
        let placement = fixture.placement(tile, runs: runs)
        let encoder = fixture.draw([placement, placement])

        let opaque = Fixture.state(.lessEqual, writes: true)
        let translucent = Fixture.state(.lessEqual, writes: false)
        XCTAssertEqual(draws(encoder), [
            Draw(pipeline: "TileSphereOpaqueFills", state: opaque, count: 12, offset: 256),
            Draw(pipeline: "TileSphereFills", state: translucent, count: 6, offset: 256 + 12 * 2),
            Draw(pipeline: "TileSphereRibbons", state: translucent, count: 6, offset: 256 + 24 * 2),
        ], "The opaque runs merged, the faded run left out, once for the source")
        XCTAssertEqual(Array(encoder.commands.prefix(2)), [.setFrontFacing(.counterClockwise), .setCullMode(.back)])
        XCTAssertEqual(Array(encoder.commands.suffix(3)), [.setDepthStencilState(GPUDepthStencilDescriptor()),
                                                          .setCullMode(.none),
                                                          .setFrontFacing(.clockwise)],
                       "Leaves the shared encoder's winding and culling as Metal's default")
        XCTAssertTrue(encoder.commands.contains(.setStencilReference(TileSourceStencilPriority.reference(sourceZoom: 5))))
        let backing = try XCTUnwrap(fixture.backing as? RecordingBuffer).name
        XCTAssertTrue(encoder.commands.contains(.setVertexBuffer(backing, offset: 1024, index: 2)), "The styles at their span")
        XCTAssertTrue(encoder.commands.contains(.setFragmentBuffer(backing, offset: 1536, index: 7)), "The line styles at their span")
        XCTAssertEqual(encoder.vertexValue(at: 12, as: TileSphereHandoverUniform.self)?.handover, 0.25)
        XCTAssertEqual(encoder.fragmentValue(at: 8, as: TileSphereHandoverUniform.self)?.handover, 0.25)
        XCTAssertEqual(encoder.vertexValue(at: 11, as: TileOverviewFadeUniform.self)?.cameraZoom, 5)
        XCTAssertEqual(encoder.vertexValue(at: 9, as: GlobeSurfaceTileUniform.self)?.uvScale, GlobeSurfaceTileUniform(tile: tile).uvScale)
    }

    func testVeiledRibbonsDrawTheirCoresHighestRankFirstThenTheirFeathers() throws {
        let fixture = try Fixture()
        let veiled = Self.ribbon | GroundStyleRun.sphereVeiledFlag
        let runs = [Self.run(0, 6, flags: Self.ribbon), Self.run(6, 6, flags: veiled)]
        let encoder = fixture.draw([fixture.placement(Tile(x: 1, y: 1, z: 3), runs: runs)])

        let owner = Fixture.state(.less, writes: true)
        let translucent = Fixture.state(.lessEqual, writes: false)
        XCTAssertEqual(draws(encoder), [
            Draw(pipeline: "TileSphereRibbonCore", state: owner, count: 6, offset: 256 + 6 * 2),
            Draw(pipeline: "TileSphereRibbonCore", state: owner, count: 6, offset: 256),
            Draw(pipeline: "TileSphereRibbonFeather", state: translucent, count: 12, offset: 256),
        ], "One core draw per run from the highest rank down, then the feathers merged")
    }

    func testTheMorphDrawsItsVariantsAndARasterPlacementItsLinesAlone() throws {
        let fixture = try Fixture()
        let runs = [Self.run(0, 6, flags: Self.opaqueFill), Self.run(6, 6, flags: Self.ribbon)]
        let raster = fixture.placement(Tile(x: 1, y: 1, z: 3), runs: runs,
                                       rules: TileDrawRules(raster: RasterTileSpec(size: 256)))
        let encoder = fixture.draw([raster], pureSphere: false)

        XCTAssertEqual(draws(encoder).map(\.pipeline), ["TileSphereMorphRibbons"],
                       "The texture is the ground, so only the ribbons draw, through the morph's variant")
    }
}
