// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import XCTest
@testable import ImmersiveMap

/// The ground's pipelines, recorded: the flat classes with their relief and
/// road variants, the sphere's classes at rest and through the morph, the
/// function constants each is made with, and which one a draw selects. No
/// picture: the ground is judged in the app.
final class TilePipelineTests: XCTestCase {
    private func descriptor(_ pipeline: any GPURenderPipeline) throws -> GPURenderPipelineDescriptor {
        try XCTUnwrap((pipeline as? RecordingRenderPipeline)?.descriptor)
    }

    func testTheFlatSurfaceHasEachClassPlainOnTheReliefAndAsRoads() throws {
        let device = RecordingGPUDevice()
        let pipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4, readsGroundShadowMask: true)
        let labels = device.pipelines.compactMap(\.label)
        XCTAssertEqual(labels.count, 10)
        XCTAssertEqual(Set(labels).count, labels.count, "Each pipeline its own name")
        for recorded in device.pipelines {
            XCTAssertEqual(recorded.vertexLayout, TileVertexIn.gpuVertexLayout)
            XCTAssertEqual(recorded.depthStencilFormat, .depth32FloatStencil8)
            XCTAssertEqual(recorded.sampleCount, 4)
        }

        let lines = try descriptor(pipeline.linesPipeline)
        XCTAssertEqual(lines.vertexFunction.constants, [0: .bool(true), 1: .bool(true), 4: .bool(false), 5: .bool(false), 6: .bool(false)])
        XCTAssertEqual(lines.colorTargets.first?.blend?.color, GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha))
        XCTAssertEqual(lines.colorTargets.first?.blend?.alpha, GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))

        let opaque = try descriptor(pipeline.flatOpaquePipeline)
        XCTAssertNil(opaque.colorTargets.first?.blend, "The opaque ground draws unblended")
        XCTAssertEqual(opaque.fragmentFunction?.constants[1], .bool(false), "The fills carry no line fields")

        let relief = try descriptor(try XCTUnwrap(pipeline.flatReliefPipeline(.fills)))
        XCTAssertEqual(relief.vertexFunction.constants[6], .bool(true))
        XCTAssertEqual(relief.vertexFunction.constants[0], .bool(false), "The relief samples the cascades, not the plane's mask")

        let road = try descriptor(try XCTUnwrap(pipeline.flatRoadPipeline(blended: false)))
        XCTAssertEqual(road.fragmentFunction?.name, "tileRoadFragmentShader")
        XCTAssertEqual(road.fragmentFunction?.constants[4], .bool(true))
        XCTAssertNil(road.colorTargets.first?.blend)
        let blendedRoad = try descriptor(try XCTUnwrap(pipeline.flatRoadPipeline(blended: true)))
        XCTAssertEqual(blendedRoad.fragmentFunction?.constants[5], .bool(true))
        XCTAssertNotNil(blendedRoad.colorTargets.first?.blend)

        XCTAssertTrue(pipeline.sphereClassPipeline(linesClass: true, morph: false) === pipeline.pipelineState,
                      "A flat pipeline has no sphere class and falls back to its own")
    }

    func testTheSphereHasItsClassesAtRestAndThroughTheMorph() throws {
        let device = RecordingGPUDevice()
        let pipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4, surface: .sphere)
        let labels = device.pipelines.compactMap(\.label)
        XCTAssertEqual(labels.count, 11)
        XCTAssertEqual(Set(labels).count, labels.count, "Each pipeline its own name")
        XCTAssertNil(pipeline.flatRoadPipeline(blended: true))
        XCTAssertNil(pipeline.flatReliefPipeline(.fills))

        let morph = try descriptor(pipeline.pipelineState)
        XCTAssertEqual(morph.vertexFunction.name, "tileSphereMorphVertexShader")
        XCTAssertEqual(morph.vertexFunction.constants, [0: .bool(true), 1: .bool(true), 2: .int32(0)])

        let core = try descriptor(pipeline.sphereClassPipeline(linesClass: true, morph: false, ribbonPhase: .core))
        XCTAssertEqual(core.vertexFunction.name, "tileSpherePureVertexShader")
        XCTAssertEqual(core.fragmentFunction?.constants, [0: .bool(false), 1: .bool(true), 2: .int32(1)])
        let feather = try descriptor(pipeline.sphereClassPipeline(linesClass: true, morph: true, ribbonPhase: .feather))
        XCTAssertEqual(feather.fragmentFunction?.constants, [0: .bool(true), 1: .bool(true), 2: .int32(2)])

        let opaque = try descriptor(pipeline.sphereOpaqueFillsPipeline(morph: true))
        XCTAssertNil(opaque.colorTargets.first?.blend)
        XCTAssertEqual(opaque.vertexFunction.constants[1], .bool(false))
    }

    func testASelectionSetsThatPipelineOnTheEncoder() throws {
        let device = RecordingGPUDevice()
        let pipeline = TilePipeline(device: device, pixelFormat: .bgra8Unorm)
        let encoder = RecordingRenderEncoder()
        XCTAssertTrue(pipeline.selectFlatReliefPipeline(.roadBlended, renderEncoder: encoder))
        pipeline.selectFlatOpaquePipeline(renderEncoder: encoder)
        XCTAssertEqual(encoder.commands, [.setPipeline(try descriptor(try XCTUnwrap(pipeline.flatReliefPipeline(.roadBlended)))),
                                          .setPipeline(try descriptor(pipeline.flatOpaquePipeline))])
    }
}
