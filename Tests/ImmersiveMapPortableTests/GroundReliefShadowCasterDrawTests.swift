// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the mountains' shadow casters ask of the GPU, recorded, over a
/// terrain store that holds no tile: the pass set up and handed back
/// neutral, and no caster without its terrain. The casters over terrain
/// need terrain tiles and are left to the app. No picture.
final class GroundReliefShadowCasterDrawTests: XCTestCase {
    private struct Fixture {
        let device = RecordingGPUDevice()
        let drawing: GroundReliefShadowCasterDrawing
        let relief: GroundReliefFrame

        init() throws {
            var depth = GPUDepthStencilDescriptor()
            depth.depthCompare = .less
            depth.depthWriteEnabled = true
            let pipeline = RasterTilePipeline(device: device, pixelFormat: .bgra8Unorm)
            drawing = GroundReliefShadowCasterDrawing(pipeline: pipeline,
                                                      grid: RasterTileGrid(device: device),
                                                      depthState: try XCTUnwrap(device.makeDepthStencilState(depth)),
                                                      groundFlattening: .init())
            let settings = ImmersiveMapSettings.TileSettings.GroundReliefSettings(isEnabled: true, minimumSourceZoom: 0)
            let store = GroundReliefStore(device: device,
                                          settings: settings,
                                          source: GroundReliefURLTerrainSource(settings: settings, fetch: { _ in .missing }))
            relief = GroundReliefFrameState(store: store, settings: settings).frame
        }

        func encode(_ placements: [PlaceTile]) -> RecordingRenderEncoder {
            let encoder = RecordingRenderEncoder()
            drawing.encode(placements: placements,
                           relief: relief,
                           lightProjectionView: matrix_identity_float4x4,
                           flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                           encoder: encoder)
            return encoder
        }
    }

    func testThePassIsSetUpForTheLightAndHandedBackNeutral() throws {
        let fixture = try Fixture()
        let placement = try TestTiles.placement(device: fixture.device, source: Tile(x: 40, y: 20, z: 14))
        let encoder = fixture.encode([placement])

        let caster = try XCTUnwrap(fixture.device.pipelines.first { $0.label == "RasterTileReliefShadow" })
        XCTAssertEqual(encoder.commands.first, .pushDebugGroup("relief.shadowCasters"))
        XCTAssertTrue(encoder.commands.contains(.setPipeline(caster)))
        XCTAssertTrue(encoder.commands.contains(.setDepthClipMode(.clamp)), "Mountains behind the light's near plane still cast")
        XCTAssertTrue(encoder.commands.contains(.setDepthBias(GPUDepthBias(constant: 0,
                                                                           slopeScale: GroundReliefShadowCasterDrawing.slopeDepthBias,
                                                                           clamp: 0))))
        XCTAssertNotNil(encoder.vertexValue(at: 1, as: ShadowCasterUniform.self))
        XCTAssertEqual(Array(encoder.commands.suffix(3)), [.setDepthBias(.none), .setDepthClipMode(.clip), .popDebugGroup])
    }

    func testNoTerrainCastsNothing() throws {
        let fixture = try Fixture()
        let plane = try TestTiles.placement(device: fixture.device, source: Tile(x: 40, y: 20, z: 14))
        let tile = Tile(x: 41, y: 20, z: 14)
        let unloaded = PlaceTile(metalTile: plane.metalTile,
                                 placeIn: VisibleTile(tile: tile),
                                 terrain: Tile(x: 10, y: 5, z: 12))
        let encoder = fixture.encode([plane, unloaded])
        let draws = encoder.commands.filter { if case .drawIndexed = $0 { return true } else { return false } }
        XCTAssertTrue(draws.isEmpty, "Neither the plane's tile nor one whose terrain is not in rises")
    }

    func testTheHorizonBackdropAndNoPlacementsDrawNothing() throws {
        let fixture = try Fixture()
        let tile = Tile(x: 1, y: 1, z: 3)
        let backdrop = PlaceTile(metalTile: try TestTiles.placement(device: fixture.device, source: tile).metalTile,
                                 placeIn: VisibleTile(tile: tile),
                                 isHorizonBackdrop: true)
        XCTAssertTrue(fixture.encode([backdrop]).commands.isEmpty)
        XCTAssertTrue(fixture.encode([]).commands.isEmpty)
    }
}
