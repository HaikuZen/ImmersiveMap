// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the buildings ask of the GPU, recorded: their pipelines, the
/// buildings of each tile with the shadow map and their rise, the relief's
/// lifts, and the shadow casters. No picture: the buildings are judged in
/// the app.
final class BuildingDrawTests: XCTestCase {
    private struct Fixture {
        let device: RecordingGPUDevice
        let pipeline: ExtrudedTilePipeline
        let indexBuffers: HiddenBuildingIndexBuffers
        let depthTest: any GPUDepthStencilState
        let disabled: any GPUDepthStencilState
        let shadowMap: any GPUTexture

        init() throws {
            let device = RecordingGPUDevice()
            self.device = device
            pipeline = ExtrudedTilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
            indexBuffers = HiddenBuildingIndexBuffers(device: device)
            var test = GPUDepthStencilDescriptor()
            test.depthCompare = .less
            test.depthWriteEnabled = true
            depthTest = try XCTUnwrap(device.makeDepthStencilState(test))
            disabled = try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor()))
            shadowMap = try XCTUnwrap(device.makeTexture(GPUTextureDescriptor(format: .depth16Unorm, width: 8, height: 8)))
        }

        /// A tile of 12 building indices, kept by quarters of 4, 2, 2 and 4,
        /// drawn by the quarters `quarters` selects.
        func placement(_ tile: Tile, quarters: UInt8 = TileQuarters.all) throws -> PlaceTile {
            let backing = try XCTUnwrap(device.makeBuffer(length: 1024, storage: .shared))
            var extruded = TileBuffers.Extruded(vertices: TileBufferView(gpuBuffer: backing, offset: 0, count: 8),
                                                indices: TileBufferView(gpuBuffer: backing, offset: 512, count: 12),
                                                styles: TileBufferView(gpuBuffer: backing, offset: 768, count: 1),
                                                gpuIndexType: .uint16)
            extruded.quarterIndexStarts = [0, 4, 6, 8, 12]
            return PlaceTile(metalTile: MetalTile(tile: tile, tileBuffers: TestTiles.buffers(backing: backing, extruded: extruded)),
                             placeIn: VisibleTile(tile: tile),
                             quarters: quarters)
        }
    }

    private func indexedDraws(_ encoder: RecordingRenderEncoder) -> [(count: Int, offset: Int)] {
        encoder.commands.compactMap { command in
            guard case let .drawIndexed(_, count, _, _, offset, _, _, _) = command else { return nil }
            return (count, offset)
        }
    }

    func testTheBuildingsAndTheirCastersHaveAPipelineOnAndOffTheRelief() throws {
        let fixture = try Fixture()
        let pipelines = fixture.device.pipelines
        XCTAssertEqual(pipelines.count, 4)
        let buildings = try XCTUnwrap(pipelines.first { $0.label == "ExtrudedTiles" })
        XCTAssertEqual(buildings.vertexFunction.constants, [0: .bool(false)])
        XCTAssertEqual(buildings.sampleCount, 4)
        XCTAssertEqual(buildings.vertexLayout?.attributes[0], GPUVertexAttribute(format: .short3, offset: 0, bufferIndex: 0))
        XCTAssertEqual(buildings.vertexLayout?.attributes[1], GPUVertexAttribute(format: .char3Normalized, offset: 6, bufferIndex: 0))
        XCTAssertEqual(buildings.vertexLayout?.strides[0], MemoryLayout<ExtrudedVertexIn>.stride)
        let casters = try XCTUnwrap(pipelines.first { $0.label == "ExtrudedTileCastersRelief" })
        XCTAssertEqual(casters.vertexFunction.constants, [0: .bool(true)])
        XCTAssertTrue(casters.colorTargets.isEmpty, "The casters write depth alone")
        XCTAssertNil(casters.fragmentFunction)
        XCTAssertEqual(casters.depthStencilFormat, ShadowCascadeAtlas.depthFormat)
        XCTAssertEqual(casters.sampleCount, 1)
    }

    func testEachTileDrawsItsQuartersWithTheShadowMapAndItsRise() throws {
        let fixture = try Fixture()
        let placement = try fixture.placement(Tile(x: 9904, y: 5121, z: 15), quarters: 0b0101)
        var shadow = ShadowUniform.disabled
        shadow.strength = 0.4
        let encoder = RecordingRenderEncoder()
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: SIMD3(0, 0, 3), padding: 0),
                                              shadowUniform: shadow,
                                              shadowMap: fixture.shadowMap,
                                              placeTilesContext: PlaceTilesContext(tilePlacements: [placement]),
                                              indexBuffers: fixture.indexBuffers,
                                              flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                                              heightScales: [0.5],
                                              extrudedTilePipeline: fixture.pipeline,
                                              extrudedStencilTestState: fixture.depthTest,
                                              depthDisabledState: fixture.disabled)

        XCTAssertEqual(encoder.commands.first, .setFrontFacing(.clockwise))
        XCTAssertTrue(encoder.commands.contains(.setFragmentTexture((fixture.shadowMap as! RecordingTexture).name, index: 0)))
        XCTAssertEqual(encoder.fragmentValue(at: 5, as: ShadowUniform.self)?.strength, 0.4)
        XCTAssertNotNil(encoder.fragmentValue(at: 6, as: Float.self), "The depth cue's metres to world units")
        XCTAssertTrue(encoder.commands.contains(.setStencilReference(TileSourceStencilPriority.reference(sourceZoom: 15)
                                                                         | TileSourceStencilPriority.surfaceMaskBit)))
        let draws = indexedDraws(encoder)
        XCTAssertEqual(draws.map(\.count), [4, 2], "One draw per run of the quarters drawn, quarters 0 and 2")
        XCTAssertEqual(draws.map(\.offset), [512, 512 + 6 * 2], "Each run's indices at its place in the tile's buffer")
        let model = try XCTUnwrap(encoder.vertexValue(at: 3, as: matrix_float4x4.self))
        XCTAssertEqual(model.columns.2.z, model.columns.0.x * 0.5, accuracy: 1e-6, "The rise scales the height alone")
        XCTAssertEqual(Array(encoder.commands.suffix(2)), [.setCullMode(.none), .setDepthStencilState(GPUDepthStencilDescriptor())])
    }

    func testATileOnTheReliefDrawsWithItsLifts() throws {
        let fixture = try Fixture()
        let flat = try fixture.placement(Tile(x: 1, y: 1, z: 15))
        let lifted = try fixture.placement(Tile(x: 2, y: 1, z: 15))
        let lifts = try XCTUnwrap(fixture.device.makeBuffer([Float](repeating: 120, count: 4), storage: .shared))
        let encoder = RecordingRenderEncoder()
        BuildingExtrusionDrawer.drawShadowCasters(renderEncoder: encoder,
                                                  lightProjectionView: matrix_identity_float4x4,
                                                  placeTilesContext: PlaceTilesContext(tilePlacements: [flat, lifted]),
                                                  indexBuffers: fixture.indexBuffers,
                                                  flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                                                  liftBuffers: [nil, lifts],
                                                  liftDatumMetres: 100,
                                                  liftStrength: 2,
                                                  liftUnitsPerMetre: 0.01,
                                                  extrudedTilePipeline: fixture.pipeline,
                                                  extrudedDepthState: fixture.depthTest)

        let pipelines = encoder.commands.compactMap { command -> String? in
            if case let .setPipeline(descriptor) = command { return descriptor.label }
            return nil
        }
        XCTAssertEqual(pipelines, ["ExtrudedTileCasters", "ExtrudedTileCastersRelief"])
        XCTAssertTrue(encoder.commands.contains(.setVertexBuffer((lifts as! RecordingBuffer).name, offset: 0, index: 4)))
        let lift = try XCTUnwrap(encoder.vertexValue(at: 5, as: BuildingLiftUniform.self))
        XCTAssertEqual(lift.datumMetres, 100)
        XCTAssertEqual(lift.strength, 2)
        XCTAssertNotNil(encoder.vertexValue(at: 1, as: ShadowCasterUniform.self))
        XCTAssertTrue(encoder.commands.contains(.setDepthClipMode(.clamp)), "Casters behind the light's near plane still cast")
        XCTAssertEqual(encoder.commands.last, .setDepthClipMode(.clip))
        XCTAssertEqual(indexedDraws(encoder).count, 2, "Each tile's quarters, all drawn, in one run")
    }

    func testAHiddenBuildingDrawsFromTheWorkingBuffer() throws {
        let fixture = try Fixture()
        var placement = try fixture.placement(Tile(x: 9904, y: 5121, z: 15))
        var extruded = placement.metalTile.tileBuffers.extruded
        extruded.buildingRanges = [TileBuildingRange(featureID: 1, indexStart: 0, indexCount: 6),
                                   TileBuildingRange(featureID: 2, indexStart: 6, indexCount: 6)]
        extruded.quarterIndexStarts = []
        placement = PlaceTile(metalTile: MetalTile(tile: placement.metalTile.tile,
                                                   tileBuffers: TestTiles.buffers(backing: placement.metalTile.tileBuffers.gpuBackingBuffer,
                                                                                  extruded: extruded)),
                              placeIn: placement.placeIn)
        fixture.indexBuffers.update(ReplacedBuildings(byMapTileZoom: [15: [1]]))
        let encoder = RecordingRenderEncoder()
        BuildingExtrusionDrawer.drawBuildings(renderEncoder: encoder,
                                              cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: .zero, padding: 0),
                                              shadowUniform: .disabled,
                                              shadowMap: fixture.shadowMap,
                                              placeTilesContext: PlaceTilesContext(tilePlacements: [placement]),
                                              indexBuffers: fixture.indexBuffers,
                                              flatRenderState: FlatRenderState(pan: .zero, renderMapSize: 4),
                                              extrudedTilePipeline: fixture.pipeline,
                                              extrudedStencilTestState: fixture.depthTest,
                                              depthDisabledState: fixture.disabled)
        let draws = encoder.commands.compactMap { command -> (String, Int)? in
            guard case let .drawIndexed(_, count, _, buffer, _, _, _, _) = command else { return nil }
            return (buffer, count)
        }
        XCTAssertEqual(draws.map(\.1), [6], "The other building alone")
        let tileBuffer = try XCTUnwrap(placement.metalTile.tileBuffers.gpuBackingBuffer as? RecordingBuffer)
        XCTAssertNotEqual(draws.first?.0, tileBuffer.name, "From the working copy, not the tile's own indices")
    }
}
