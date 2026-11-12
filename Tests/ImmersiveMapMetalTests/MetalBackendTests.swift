// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import XCTest

/// The Metal backend's mapping of the interface's values, and the objects it
/// makes, on the machine's Metal device. Nothing here draws: what a draw
/// looks like is judged in the app, not by pixels in a test.
final class MetalBackendTests: XCTestCase {
    func testTheValuesMapToMetals() {
        XCTAssertEqual(GPUPixelFormat.bgra8Unorm.metal, .bgra8Unorm)
        XCTAssertEqual(GPUPixelFormat.depth32FloatStencil8.metal, .depth32Float_stencil8)
        XCTAssertEqual(GPUPixelFormat.depth16Unorm.metal, .depth16Unorm)
        XCTAssertEqual(GPUPixelFormat(metal: .depth16Unorm), .depth16Unorm)
        XCTAssertEqual(GPUPixelFormat.r16Float.metal, .r16Float)
        XCTAssertEqual(GPUPixelFormat.astc(blockWidth: 8, blockHeight: 8).metal, .astc_8x8_ldr)
        XCTAssertEqual(GPUPixelFormat.astc(blockWidth: 7, blockHeight: 3).metal, .invalid)
        XCTAssertEqual(GPUCompareFunction.lessEqual.metal, .lessEqual)
        XCTAssertEqual(GPUStencilOperation.incrementWrap.metal, .incrementWrap)
        XCTAssertEqual(GPUBlendFactor.oneMinusSourceAlpha.metal, .oneMinusSourceAlpha)
        XCTAssertEqual(GPUVertexFormat.char.metal, .char)
        XCTAssertEqual(GPUVertexFormat.char2Normalized.metal, .char2Normalized)
        XCTAssertEqual(GPUVertexFormat.char3Normalized.metal, .char3Normalized)
        XCTAssertEqual(GPUVertexFormat.char4Normalized.metal, .char4Normalized)
        XCTAssertEqual(GPUPrimitiveTopology.triangleStrip.metal, .triangleStrip)
        XCTAssertEqual(GPUPrimitiveTopology.triangleStrip.metalClass, .triangle)
        XCTAssertEqual(GPUIndexType.uint16.metal, .uint16)
        XCTAssertEqual(GPUCullMode.back.metal, .back)
        XCTAssertEqual(GPUWinding.counterClockwise.metal, .counterClockwise)
        XCTAssertEqual(GPUDepthClipMode.clamp.metal, .clamp)
        XCTAssertEqual(GPUTriangleFillMode.lines.metal, .lines)
        XCTAssertEqual(GPULoadAction.load.metal, .load)
        XCTAssertEqual(GPUStoreAction.multisampleResolve.metal, .multisampleResolve)
        XCTAssertEqual(GPUTextureUsage([.shaderRead, .renderTarget]).metal, [.shaderRead, .renderTarget])
        XCTAssertEqual(GPUAddressMode.repeat.metal, .repeat)
        XCTAssertEqual(GPUFilter.linear.metalMinMag, .linear)
        XCTAssertEqual(GPUFilter.nearest.metalMip, .nearest)
    }

    /// A device and a library compiled from source, or a skip on a machine
    /// without Metal.
    private func makeDevice() throws -> MetalDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        constant bool tinted [[function_constant(0)]];
        struct Out { float4 position [[position]]; };
        vertex Out vertexMain(uint id [[vertex_id]], constant float2 *points [[buffer(0)]]) {
            return Out { float4(points[id], 0, 1) };
        }
        fragment float4 fragmentMain(Out in [[stage_in]]) {
            return tinted ? float4(1, 0, 0, 1) : float4(1);
        }
        """
        return MetalDevice(device: device, library: try device.makeLibrary(source: source, options: nil))
    }

    func testBuffersHoldWhatIsWritten() throws {
        let device = try makeDevice()
        var values: [Float] = [1, 2, 3, 4]
        let buffer = try XCTUnwrap(device.makeBuffer(bytes: &values, length: 16, storage: .shared))
        XCTAssertEqual(buffer.length, 16)
        XCTAssertEqual(buffer.contents().load(fromByteOffset: 8, as: Float.self), 3)
        buffer.contents().storeBytes(of: 9, toByteOffset: 0, as: Float.self)
        XCTAssertEqual((buffer as? MetalBuffer)?.buffer.contents().load(as: Float.self), 9)
    }

    func testTexturesAreMadeAsDescribed() throws {
        let device = try makeDevice()
        var descriptor = GPUTextureDescriptor(format: .r8Unorm, width: 4, height: 2)
        descriptor.type = .type2DArray
        descriptor.arrayLength = 3
        descriptor.storage = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor))
        XCTAssertEqual(texture.width, 4)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.arrayLength, 3)
        XCTAssertEqual(texture.type, .type2DArray)
        XCTAssertEqual(texture.format, .r8Unorm)

        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        bytes.withUnsafeBytes { raw in
            texture.replace(x: 0, y: 0, width: 4, height: 2, mipmapLevel: 0, slice: 2,
                            bytes: raw.baseAddress!, bytesPerRow: 4)
        }
        var readBack = [UInt8](repeating: 0, count: 8)
        let metal = try XCTUnwrap((texture as? MetalTexture)?.texture)
        readBack.withUnsafeMutableBytes { raw in
            metal.getBytes(raw.baseAddress!, bytesPerRow: 4, bytesPerImage: 8,
                           from: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0, slice: 2)
        }
        XCTAssertEqual(readBack, bytes)
    }

    func testStatesAndPipelinesAreMade() throws {
        let device = try makeDevice()
        var stencil = GPUStencilFaceState()
        stencil.compare = .equal
        stencil.pass = .replace
        var depth = GPUDepthStencilDescriptor()
        depth.depthCompare = .lessEqual
        depth.depthWriteEnabled = true
        depth.frontStencil = stencil
        depth.backStencil = stencil
        XCTAssertNotNil(device.makeDepthStencilState(depth))

        var sampler = GPUSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.addressModeU = .repeat
        XCTAssertNotNil(device.makeSampler(sampler))

        var color = GPUColorTarget(format: .bgra8Unorm)
        color.blend = (GPUBlendComponent(source: .sourceAlpha, destination: .oneMinusSourceAlpha),
                       GPUBlendComponent(source: .one, destination: .oneMinusSourceAlpha))
        var pipeline = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "vertexMain"),
                                                   fragmentFunction: GPUShaderFunction(name: "fragmentMain",
                                                                                       constants: [0: .bool(true)]),
                                                   colorTargets: [color])
        pipeline.depthStencilFormat = .depth32FloatStencil8
        pipeline.label = "test"
        XCTAssertNoThrow(try device.makeRenderPipeline(pipeline))

        pipeline.vertexFunction = GPUShaderFunction(name: "noSuchFunction")
        XCTAssertThrowsError(try device.makeRenderPipeline(pipeline)) { error in
            XCTAssertEqual(error as? GPUError, .missingFunction("noSuchFunction"))
        }
    }

    func testACommandBufferEncodesAndCompletes() throws {
        let device = try makeDevice()
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        commandBuffer.label = "test"
        XCTAssertEqual(commandBuffer.label, "test")
        let target = try XCTUnwrap(device.makeTexture({
            var descriptor = GPUTextureDescriptor(format: .bgra8Unorm, width: 8, height: 8)
            descriptor.usage = .renderTarget
            return descriptor
        }()))
        let encoder = try XCTUnwrap(commandBuffer.makeRenderEncoder(GPURenderPassDescriptor(
            colorAttachments: [GPUColorAttachment(texture: target)])))
        encoder.setCullMode(.back)
        encoder.setFrontFacing(.counterClockwise)
        encoder.setDepthBias(GPUDepthBias(constant: 1, slopeScale: 1, clamp: 0))
        encoder.pushDebugGroup("group")
        encoder.popDebugGroup()
        encoder.endEncoding()
        let completed = expectation(description: "completed")
        commandBuffer.addCompletedHandler { completed.fulfill() }
        commandBuffer.commit()
        wait(for: [completed], timeout: 10)
    }
}
