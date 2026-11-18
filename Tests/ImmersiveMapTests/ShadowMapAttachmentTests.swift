// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import XCTest

/// The shadow map is one plain 2D depth texture. That is what keeps the pass
/// off layered rendering, which the iOS Simulator does not implement: a
/// descriptor asking for more than one slice fails Metal validation there and
/// aborts the process rather than returning an error, which is how shadows
/// used to crash at launch and then had to be dropped on the simulator
/// entirely. Nothing here may reintroduce an array slice.
final class ShadowMapAttachmentTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        return device
    }

    /// Layered rendering is what fails validation and aborts the process:
    /// the clear is one plain pass a slice, which the interface's pass, one
    /// slice at most, cannot get wrong.
    @MainActor
    func testTheFallbackClearIsAPlainPassPerSlice() throws {
        let device = reliefGPUDevice(try makeDevice())
        var descriptor = GPUTextureDescriptor(format: ShadowCascadeAtlas.depthFormat, width: 1, height: 1)
        descriptor.type = .type2DArray
        descriptor.arrayLength = ShadowCascadeAtlas.sliceCount
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor))

        for slice in 0..<ShadowCascadeAtlas.sliceCount {
            let pass = RenderResources.fallbackClearPass(texture: texture, slice: slice)

            XCTAssertTrue(pass.colorAttachments.isEmpty)
            let depth = try XCTUnwrap(pass.depthStencilAttachment)
            XCTAssertEqual(depth.slice, slice)
            XCTAssertEqual(depth.load, .clear)
            XCTAssertEqual(depth.store, .store)
            XCTAssertEqual(depth.clearDepth, 1.0)
        }
    }

    /// Building the shared resources is what crashed at launch, so it is done
    /// here too: on the simulator this is the path that used to abort.
    @MainActor
    func testSharedResourcesBuildWhereverTheTestsRun() throws {
        let device = try makeDevice()
        guard (try? device.makeDefaultLibrary(bundle: ImmersiveMapResourceBundle.bundle())) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let fallback = try SharedRenderResources.shared(sampleCount: 1).shadowFallbackTexture.metalTexture

        XCTAssertEqual(fallback.textureType, .type2DArray)
        XCTAssertEqual(fallback.arrayLength, ShadowCascadeAtlas.sliceCount)
        XCTAssertEqual(fallback.pixelFormat, ShadowCascadeAtlas.depthPixelFormat)
    }

    /// The render attachment the caster passes write: same shape as the
    /// fallback, a slice a window, so the receivers' `depth2d_array<float>`
    /// binding matches at runtime.
    @MainActor
    func testTheShadowMapAttachmentHasASlicePerWindow() throws {
        let device = try makeDevice()
        let attachments = FrameAttachmentStore(device: reliefGPUDevice(device), renderSampleCount: 1)

        let texture = try XCTUnwrap(attachments.ensureShadowMapTexture(resolution: 512)?.metalTexture)

        XCTAssertEqual(texture.textureType, .type2DArray)
        XCTAssertEqual(texture.arrayLength, ShadowCascadeAtlas.sliceCount)
        XCTAssertEqual(texture.width, 512)
        XCTAssertEqual(texture.height, 512)
        XCTAssertEqual(texture.pixelFormat, ShadowCascadeAtlas.depthPixelFormat)
    }
}
