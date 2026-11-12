// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the starfield asks of the GPU, recorded: its pipeline, its stars and
/// the values its shaders read, and one draw of points. No picture: the sky
/// is judged in the app.
final class StarfieldDrawTests: XCTestCase {
    private func makeRenderer(device: RecordingGPUDevice, starCount: Int) -> StarfieldRenderer {
        var config = ImmersiveMapSettings.default.scene.starfield
        config.starCount = starCount
        let pipeline = StarfieldPipeline(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        return StarfieldRenderer(device: device, pipeline: pipeline, config: config)
    }

    func testThePipelineDrawsAdditivePointsFromOneBuffer() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["starfieldVertexShader", "starfieldFragmentShader"])
        _ = makeRenderer(device: device, starCount: 3)
        let pipeline = try XCTUnwrap(device.pipelines.first)
        XCTAssertEqual(pipeline.topology, .point)
        XCTAssertEqual(pipeline.sampleCount, 4)
        XCTAssertEqual(pipeline.depthStencilFormat, .depth32FloatStencil8)
        XCTAssertEqual(pipeline.colorTargets.first?.blend?.color,
                       GPUBlendComponent(source: .sourceAlpha, destination: .one))
        XCTAssertEqual(pipeline.colorTargets.first?.blend?.alpha,
                       GPUBlendComponent(source: .one, destination: .one))
        let layout = try XCTUnwrap(pipeline.vertexLayout)
        XCTAssertEqual(layout.attributes.count, 6)
        XCTAssertEqual(layout.attributes[0]?.format, .float3)
        XCTAssertEqual(layout.attributes[5]?.offset, MemoryLayout<SIMD3<Float>>.stride + 4 * MemoryLayout<Float>.stride)
        XCTAssertEqual(layout.strides[0], MemoryLayout<SIMD3<Float>>.stride + 8 * MemoryLayout<Float>.stride)
    }

    func testADrawSetsTheStarsTheCameraTheGlobeAndTheTime() throws {
        let device = RecordingGPUDevice()
        let renderer = makeRenderer(device: device, starCount: 5)
        let encoder = RecordingRenderEncoder()
        let globe = GlobeUniform(panX: 0.25, panY: -0.5, radius: 0.8, transition: 0)
        renderer.draw(renderEncoder: encoder,
                      globe: globe,
                      cameraView: matrix_identity_float4x4,
                      cameraEye: SIMD3<Float>(0, 0, 3),
                      drawSize: CGSize(width: 400, height: 200),
                      nowTime: 12.5)

        XCTAssertEqual(encoder.commands.first, .setPipeline(try XCTUnwrap(device.pipelines.first)))
        XCTAssertTrue(encoder.commands.contains(.setVertexBuffer("buffer 0", offset: 0, index: 0)))
        XCTAssertEqual(encoder.commands.last, .draw(.point, vertexStart: 0, vertexCount: 5, instanceCount: 1, baseInstance: 0))

        let camera = try XCTUnwrap(encoder.vertexValue(at: 1, as: CameraUniform.self))
        XCTAssertEqual(camera.eye, SIMD3<Float>(0, 0, 3))
        let sentGlobe = try XCTUnwrap(encoder.vertexValue(at: 2, as: GlobeUniform.self))
        XCTAssertEqual(sentGlobe.panX, 0.25)
        XCTAssertEqual(sentGlobe.radius, 0.8)
        XCTAssertNotNil(encoder.vertexValue(at: 3, as: simd_float4x4.self))
        XCTAssertEqual(encoder.fragmentValue(at: 0, as: Float.self), 12.5)
    }

    func testAnEmptySkyDrawsNothing() {
        let device = RecordingGPUDevice()
        let renderer = makeRenderer(device: device, starCount: 0)
        let encoder = RecordingRenderEncoder()
        renderer.draw(renderEncoder: encoder,
                      globe: GlobeUniform(panX: 0, panY: 0, radius: 1, transition: 0),
                      cameraView: matrix_identity_float4x4,
                      cameraEye: .zero,
                      drawSize: CGSize(width: 100, height: 100),
                      nowTime: 0)
        XCTAssertTrue(encoder.commands.isEmpty)
        XCTAssertTrue(device.buffers.isEmpty)
    }
}
