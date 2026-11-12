// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the horizon asks of the GPU, recorded: two pipelines behind the
/// side constant, the band, the uniform both shaders read, and one indexed
/// draw per side. No picture: the air is judged in the app.
final class HorizonDrawTests: XCTestCase {
    private func makeUniform() -> HorizonUniform {
        HorizonUniform(up: SIMD3<Float>(0, 0, 1), depression: 0.1,
                       center: SIMD3<Float>(0, 0, 0), sunInfluence: 0.2,
                       light: SIMD3<Float>(1, 0, 0), skyStrength: 0.3,
                       tint: SIMD3<Float>(0.5, 0.6, 0.7), whitenWeight: 0.4,
                       eye: SIMD3<Float>(0, -2, 1), featherStrength: 0.5,
                       bandRadians: 0.6, glowRadians: 0.7, whitenRadians: 0.8,
                       featherRadians: 0.9, groundBandRadians: 1.0, groundGain: 1.1,
                       cutoffStartRadians: 1.2, cutoffEndRadians: 1.3,
                       skyColor: SIMD3<Float>(0.1, 0.2, 0.3), skyOpacity: 0.75,
                       skyGradientRadians: 1.4,
                       viewProjection: matrix_identity_float4x4,
                       bandTopRadians: 1.5)
    }

    func testTwoPremultipliedPipelinesDifferOnlyInTheSideConstant() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["horizonBandVertexShader", "horizonBandFragmentShader"])
        _ = HorizonPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        XCTAssertEqual(device.pipelines.count, 2)
        let sky = try XCTUnwrap(device.pipelines.first { $0.label == "HorizonSkyPipeline" })
        let ground = try XCTUnwrap(device.pipelines.first { $0.label == "HorizonGroundPipeline" })
        XCTAssertEqual(sky.fragmentFunction?.constants, [0: .bool(false)])
        XCTAssertEqual(ground.fragmentFunction?.constants, [0: .bool(true)])
        var groundAsSky = ground
        groundAsSky.label = sky.label
        groundAsSky.fragmentFunction = sky.fragmentFunction
        XCTAssertEqual(groundAsSky, sky)

        let over = GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha)
        XCTAssertEqual(sky.colorTargets.first?.blend?.color, over)
        XCTAssertEqual(sky.colorTargets.first?.blend?.alpha, over)
        XCTAssertEqual(sky.sampleCount, 4)
        XCTAssertEqual(sky.depthStencilFormat, .depth32FloatStencil8)
        let layout = try XCTUnwrap(sky.vertexLayout)
        XCTAssertEqual(layout.attributes[0], GPUVertexAttribute(format: .float, offset: 0, bufferIndex: 0))
        XCTAssertEqual(layout.attributes[1], GPUVertexAttribute(format: .float, offset: 4, bufferIndex: 0))
        XCTAssertEqual(layout.strides[0], MemoryLayout<HorizonBandMesh.Vertex>.stride)
    }

    func testTheBandIsAClosedRingOfQuads() throws {
        let device = RecordingGPUDevice()
        let mesh = try XCTUnwrap(HorizonBandMesh(device: device))
        let segments = HorizonBandMath.segmentCount
        let stations = HorizonBandMath.stationCount
        XCTAssertEqual(mesh.indexCount, segments * (stations - 1) * 6)
        XCTAssertEqual(mesh.vertexBuffer.label, "HorizonBandVertices")
        XCTAssertEqual(mesh.indexBuffer.label, "HorizonBandIndices")

        let vertices = try XCTUnwrap(mesh.vertexBuffer as? RecordingBuffer).values(as: HorizonBandMesh.Vertex.self)
        XCTAssertEqual(vertices.count, segments * stations)
        let indices = try XCTUnwrap(mesh.indexBuffer as? RecordingBuffer).values(as: UInt16.self)
        XCTAssertEqual(indices.count, mesh.indexCount)
        XCTAssertEqual(indices.max().map(Int.init), segments * stations - 1)
        // The last segment's quads close the ring on the first segment.
        let lastQuad = Array(indices.suffix(6))
        XCTAssertTrue(lastQuad.contains(UInt16(stations - 2)))
    }

    func testADrawSendsTheUniformToBothShadersAndDrawsTheBand() throws {
        let device = RecordingGPUDevice()
        let pipeline = HorizonPipeline(device: device, pixelFormat: .bgra8Unorm)
        let renderer = HorizonRenderer(pipeline: pipeline)
        let encoder = RecordingRenderEncoder()
        renderer.draw(renderEncoder: encoder, uniform: makeUniform(), groundSide: true)

        let ground = try XCTUnwrap(device.pipelines.first { $0.label == "HorizonGroundPipeline" })
        XCTAssertEqual(encoder.commands.first, .setPipeline(ground))
        XCTAssertTrue(encoder.commands.contains(.setCullMode(.none)))
        XCTAssertTrue(encoder.commands.contains(.setVertexBuffer("buffer 0", offset: 0, index: 0)))
        XCTAssertEqual(encoder.commands.last,
                       .drawIndexed(.triangle, indexCount: pipeline.bandMesh.indexCount, indexType: .uint16,
                                    indexBuffer: "buffer 1", indexBufferOffset: 0,
                                    instanceCount: 1, baseVertex: 0, baseInstance: 0))

        let vertexUniform = try XCTUnwrap(encoder.vertexValue(at: 1, as: HorizonUniform.self))
        let fragmentUniform = try XCTUnwrap(encoder.fragmentValue(at: 0, as: HorizonUniform.self))
        XCTAssertEqual(vertexUniform.bandTopRadians, 1.5)
        XCTAssertEqual(vertexUniform.skyOpacity, 0.75)
        XCTAssertEqual(fragmentUniform.eye, SIMD3<Float>(0, -2, 1))
        XCTAssertEqual(fragmentUniform.tint, SIMD3<Float>(0.5, 0.6, 0.7))
    }

    func testTheSkySidePicksTheSkyPipeline() throws {
        let device = RecordingGPUDevice()
        let renderer = HorizonRenderer(pipeline: HorizonPipeline(device: device, pixelFormat: .bgra8Unorm))
        let encoder = RecordingRenderEncoder()
        renderer.draw(renderEncoder: encoder, uniform: makeUniform(), groundSide: false)
        let sky = try XCTUnwrap(device.pipelines.first { $0.label == "HorizonSkyPipeline" })
        XCTAssertEqual(encoder.commands.first, .setPipeline(sky))
    }
}
