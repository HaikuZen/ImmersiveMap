// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import simd
import XCTest
@testable import ImmersiveMap

/// What the ground shadow mask asks of the GPU, recorded: a single-sample
/// pipeline into the 8-bit mask, and one fullscreen triangle that reads the
/// shadow map. No picture: the shadows are judged in the app.
final class GroundShadowMaskDrawTests: XCTestCase {
    func testThePipelineWritesTheEightBitMaskAlone() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["groundShadowMaskVertexShader", "groundShadowMaskFragmentShader"])
        _ = GroundShadowMaskPipeline(device: device)
        let pipeline = try XCTUnwrap(device.pipelines.first)
        XCTAssertEqual(pipeline.colorTargets, [GPUColorTarget(format: .r8Unorm)])
        XCTAssertNil(pipeline.colorTargets.first?.blend)
        XCTAssertNil(pipeline.depthStencilFormat, "The mask pass has no depth attachment")
        XCTAssertNil(pipeline.vertexLayout, "The triangle is made in the vertex shader")
        XCTAssertEqual(pipeline.sampleCount, 1)
    }

    func testTheShadowMapIsTheSixteenBitDepthArray() {
        XCTAssertEqual(ShadowCascadeAtlas.depthFormat, .depth16Unorm)
        XCTAssertEqual(ShadowCascadeAtlas.sliceCount, ShadowCascadeSlot.allCases.count)
    }

    func testTheMaskIsOneFullscreenTriangleReadingTheShadowMap() throws {
        let device = RecordingGPUDevice()
        let pipeline = GroundShadowMaskPipeline(device: device)
        let disabled = try XCTUnwrap(device.makeDepthStencilState(GPUDepthStencilDescriptor()))
        var mapDescriptor = GPUTextureDescriptor(format: .depth16Unorm, width: 2048, height: 2048)
        mapDescriptor.type = .type2DArray
        mapDescriptor.arrayLength = ShadowCascadeAtlas.sliceCount
        let shadowMap = try XCTUnwrap(device.makeTexture(mapDescriptor))
        var shadow = ShadowUniform.disabled
        shadow.strength = 0.6
        shadow.eye = SIMD3<Float>(1, 2, 3)
        let encoder = RecordingRenderEncoder()

        GroundShadowMaskDrawing.encodeMask(encoder: encoder,
                                                   pipeline: pipeline,
                                                   depthDisabledState: disabled,
                                                   maskUniform: GroundShadowMaskUniform(projectionView: matrix_identity_float4x4,
                                                                                        viewportSize: SIMD2<Float>(320, 240)),
                                                   shadowUniform: shadow,
                                                   shadowMap: shadowMap)

        XCTAssertEqual(encoder.commands.first, .setPipeline(try XCTUnwrap(device.pipelines.first)))
        XCTAssertTrue(encoder.commands.contains(.setDepthStencilState(GPUDepthStencilDescriptor())))
        XCTAssertTrue(encoder.commands.contains(.setCullMode(.none)))
        XCTAssertTrue(encoder.commands.contains(.setFragmentTexture("texture 0", index: 0)))
        XCTAssertEqual(encoder.commands.last, .draw(.triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: 0))
        XCTAssertEqual(encoder.fragmentValue(at: 0, as: GroundShadowMaskUniform.self)?.viewportSize, SIMD2<Float>(320, 240))
        let sentShadow = try XCTUnwrap(encoder.fragmentValue(at: 1, as: ShadowUniform.self))
        XCTAssertEqual(sentShadow.strength, 0.6)
        XCTAssertEqual(sentShadow.eye, SIMD3<Float>(1, 2, 3))
    }

    /// The reuse controller tells shadow maps apart by identity only, so a
    /// new texture of any backend makes the window render again.
    func testANewShadowMapTextureIsRenderedAgain() {
        let controller = ShadowMapReuseController()
        let device = RecordingGPUDevice()
        let descriptor = GPUTextureDescriptor(format: .depth16Unorm, width: 8, height: 8)
        let first = device.makeTexture(descriptor)!
        XCTAssertTrue(controller.planShadowRender(casterKeys: [], hasModelCasters: false, texture: first))
        XCTAssertFalse(controller.planShadowRender(casterKeys: [], hasModelCasters: false, texture: first))
        let second = device.makeTexture(descriptor)!
        XCTAssertTrue(controller.planShadowRender(casterKeys: [], hasModelCasters: false, texture: second))
    }
}
