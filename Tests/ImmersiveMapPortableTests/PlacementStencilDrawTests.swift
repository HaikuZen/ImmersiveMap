// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the placement prepass asks of the GPU, recorded: stencil-only
/// pipelines over the raster grid, and the planner's marks, coarse squares
/// first, each with its source's priority. The relief's passes need a
/// terrain store and are left to the app. No picture.
final class PlacementStencilDrawTests: XCTestCase {
    private struct Fixture {
        let device: RecordingGPUDevice
        let drawing: PlacementStencilDrawing
        let states: PlacementStencilDrawing.States

        init() throws {
            let device = RecordingGPUDevice()
            self.device = device
            func state(_ compare: GPUCompareFunction) throws -> any GPUDepthStencilState {
                var descriptor = GPUDepthStencilDescriptor()
                descriptor.depthCompare = compare
                return try XCTUnwrap(device.makeDepthStencilState(descriptor))
            }
            let states = PlacementStencilDrawing.States(stencilWrite: try state(.always),
                                                    depthWrite: try state(.less),
                                                    stencilReliefWrite: try state(.lessEqual),
                                                    depthReset: try state(.greaterEqual),
                                                    depthDisabled: try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor())))
            self.states = states
            drawing = PlacementStencilDrawing(pipeline: PlacementStencilPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4),
                                              grid: RasterTileGrid(device: device),
                                              states: states,
                                              groundFlattening: .init())
        }

        func encode(_ placements: [PlaceTile], surface: PlacementStencilDrawing.Surface) -> RecordingRenderEncoder {
            let encoder = RecordingRenderEncoder()
            drawing.encode(placements: placements,
                           cameraUniform: CameraUniform(matrix: matrix_identity_float4x4, eye: SIMD3(0, 0, 3), padding: 0),
                           surface: surface,
                           encoder: encoder)
            return encoder
        }
    }

    private func stencilReferences(_ encoder: RecordingRenderEncoder) -> [UInt32] {
        encoder.commands.compactMap { command in
            if case let .setStencilReference(value) = command { return value }
            return nil
        }
    }

    func testThePipelinesWriteTheStencilAlone() throws {
        let fixture = try Fixture()
        let pipelines = fixture.device.pipelines
        XCTAssertEqual(pipelines.count, 5)
        for pipeline in pipelines {
            XCTAssertNil(pipeline.fragmentFunction)
            XCTAssertEqual(pipeline.colorTargets.first?.writesColor, false)
            XCTAssertEqual(pipeline.depthStencilFormat, .depth32FloatStencil8)
            XCTAssertEqual(pipeline.sampleCount, 4)
        }
        let relief = pipelines.filter { $0.vertexFunction.constants == [0: .bool(true)] }
        XCTAssertEqual(relief.map(\.label), ["PlacementStencilFlatRelief"], "Only the relief's grid rises")
    }

    func testThePlaneMarksCoarseSquaresFirstWithTheirSourcesPriority() throws {
        let fixture = try Fixture()
        let fine = try TestTiles.placement(device: fixture.device, source: Tile(x: 40, y: 20, z: 14))
        let coarse = try TestTiles.placement(device: fixture.device, source: Tile(x: 10, y: 5, z: 12))
        let standIn = try TestTiles.placement(device: fixture.device,
                                              source: Tile(x: 5, y: 2, z: 11),
                                              placeIn: Tile(x: 20, y: 10, z: 13))
        let encoder = fixture.encode([fine, standIn, coarse],
                                     surface: .flat(FlatRenderState(pan: .zero, renderMapSize: 4), relief: nil))

        XCTAssertEqual(stencilReferences(encoder),
                       [12, 11, 14].map { TileSourceStencilPriority.reference(sourceZoom: $0) },
                       "By the square's zoom, each with its source's priority")
        let draws = encoder.commands.filter { if case .drawIndexed = $0 { return true } else { return false } }
        XCTAssertEqual(draws.count, 3)
        XCTAssertNotNil(encoder.vertexValue(at: 3, as: matrix_float4x4.self), "Each square placed by its matrix")
        XCTAssertEqual(encoder.commands.first, .pushDebugGroup("ground.placementStencil"))
        XCTAssertTrue(encoder.commands.contains(.setPipeline(try XCTUnwrap(fixture.device.pipelines.first { $0.label == "PlacementStencilFlat" }))))
        XCTAssertFalse(encoder.commands.contains(.setDepthBias(GPUDepthBias(constant: 1, slopeScale: 1, clamp: 0))),
                       "The plane writes no depth")
        XCTAssertEqual(Array(encoder.commands.suffix(4)),
                       [.setCullMode(.none), .setFrontFacing(.clockwise),
                        .setDepthStencilState(GPUDepthStencilDescriptor()), .popDebugGroup])
    }

    func testTheSphereBindsTheGlobeAndMarksEachSquareOnItsGrid() throws {
        let fixture = try Fixture()
        let placement = try TestTiles.placement(device: fixture.device,
                                                source: Tile(x: 1, y: 1, z: 3),
                                                placeIn: Tile(x: 2, y: 3, z: 4))
        let globe = GlobeUniform(panX: 0.1, panY: 0, radius: 1, transition: 0)
        let encoder = fixture.encode([placement], surface: .sphere(globe: globe, pureSphere: true))

        let pipeline = try XCTUnwrap(fixture.device.pipelines.first { $0.label == "PlacementStencilSpherePure" })
        XCTAssertTrue(encoder.commands.contains(.setPipeline(pipeline)))
        XCTAssertEqual(encoder.vertexValue(at: 8, as: GlobeUniform.self)?.panX, 0.1)
        XCTAssertNotNil(encoder.vertexValue(at: 10, as: GlobeFrameConstantsUniform.self))
        XCTAssertNotNil(encoder.vertexValue(at: 9, as: GlobeSurfaceTileUniform.self))
        XCTAssertEqual(stencilReferences(encoder), [TileSourceStencilPriority.reference(sourceZoom: 3)])
        let mesh = try XCTUnwrap(fixture.drawing.grid.mesh(forTileZoom: 4))
        XCTAssertTrue(encoder.commands.contains { command in
            if case let .drawIndexed(_, count, _, _, _, _, _, _) = command { return count == mesh.indexCount }
            return false
        }, "The square's zoom picks the grid")
    }

    func testNoPlacementsDrawNothing() throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.encode([], surface: .flat(FlatRenderState(pan: .zero, renderMapSize: 4), relief: nil)).commands.isEmpty)
    }
}
