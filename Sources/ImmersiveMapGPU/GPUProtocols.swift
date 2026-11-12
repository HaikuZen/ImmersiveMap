// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The GPU objects the engine works with, as protocols a backend conforms
// to: Metal on Apple's platforms, WebGPU elsewhere. Shaped after what the
// engine does with Metal today, so a feature moves onto them call for call.

/// A GPU memory allocation.
package protocol GPUBuffer: AnyObject {
    var length: Int { get }
    /// A name for GPU captures and debuggers. No effect on drawing.
    var label: String? { get set }

    /// The buffer's bytes, for a buffer made with `.shared` storage. A
    /// backend whose GPU memory the CPU cannot map (WebGPU) gives a copy
    /// that it uploads when the commands that read the buffer are
    /// committed, so a write after that waits for the next frame's commands.
    func contents() -> UnsafeMutableRawPointer
}

package protocol GPUTexture: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var arrayLength: Int { get }
    var format: GPUPixelFormat { get }
    var type: GPUTextureType { get }

    /// Writes the bytes into a region of one slice and mip level.
    func replace(x: Int, y: Int, width: Int, height: Int,
                 mipmapLevel: Int, slice: Int,
                 bytes: UnsafeRawPointer, bytesPerRow: Int)
}

package protocol GPUSampler: AnyObject {}

package protocol GPUDepthStencilState: AnyObject {}

package protocol GPURenderPipeline: AnyObject {}

package struct GPUColorAttachment {
    package var texture: any GPUTexture
    package var resolveTexture: (any GPUTexture)?
    package var load: GPULoadAction = .clear
    package var store: GPUStoreAction = .store
    package var clearColor = GPUClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    package init(texture: any GPUTexture) {
        self.texture = texture
    }
}

package struct GPUDepthStencilAttachment {
    package var texture: any GPUTexture
    package var load: GPULoadAction = .clear
    package var store: GPUStoreAction = .dontCare
    package var clearDepth: Double = 1
    package var clearStencil: UInt32 = 0

    package init(texture: any GPUTexture) {
        self.texture = texture
    }
}

package struct GPURenderPassDescriptor {
    package var colorAttachments: [GPUColorAttachment]
    package var depthStencilAttachment: GPUDepthStencilAttachment?
    package var label: String?

    package init(colorAttachments: [GPUColorAttachment], depthStencilAttachment: GPUDepthStencilAttachment? = nil) {
        self.colorAttachments = colorAttachments
        self.depthStencilAttachment = depthStencilAttachment
    }
}

/// Encodes the draws of one render pass. The state set on it holds until it
/// is set again or the pass ends, as on a Metal render encoder.
package protocol GPURenderEncoder: AnyObject {
    func setPipeline(_ pipeline: any GPURenderPipeline)
    func setDepthStencilState(_ state: any GPUDepthStencilState)
    func setStencilReference(_ value: UInt32)
    func setCullMode(_ mode: GPUCullMode)
    func setFrontFacing(_ winding: GPUWinding)
    func setDepthBias(_ bias: GPUDepthBias)
    func setDepthClipMode(_ mode: GPUDepthClipMode)
    func setTriangleFillMode(_ mode: GPUTriangleFillMode)
    func setViewport(_ viewport: GPUViewport)
    func setScissorRect(_ rect: GPUScissorRect)

    func setVertexBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int)
    /// Small constant data, copied when the call is made: the bytes may be
    /// changed or freed as soon as it returns. At most 4 KiB.
    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setVertexTexture(_ texture: (any GPUTexture)?, index: Int)
    func setFragmentBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int)
    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int)
    func setFragmentTexture(_ texture: (any GPUTexture)?, index: Int)
    func setFragmentSampler(_ sampler: (any GPUSampler)?, index: Int)

    func draw(_ topology: GPUPrimitiveTopology, vertexStart: Int, vertexCount: Int,
              instanceCount: Int, baseInstance: Int)
    func drawIndexed(_ topology: GPUPrimitiveTopology, indexCount: Int, indexType: GPUIndexType,
                     indexBuffer: any GPUBuffer, indexBufferOffset: Int,
                     instanceCount: Int, baseVertex: Int, baseInstance: Int)

    func pushDebugGroup(_ name: String)
    func popDebugGroup()
    func endEncoding()
}

package protocol GPUBlitEncoder: AnyObject {
    func copy(from source: any GPUBuffer, sourceOffset: Int,
              to destination: any GPUBuffer, destinationOffset: Int, size: Int)
    func copy(from source: any GPUBuffer, sourceOffset: Int, bytesPerRow: Int,
              to texture: any GPUTexture, slice: Int, mipmapLevel: Int,
              x: Int, y: Int, width: Int, height: Int)
    func generateMipmaps(for texture: any GPUTexture)
    func endEncoding()
}

package protocol GPUCommandBuffer: AnyObject {
    var label: String? { get set }

    func makeRenderEncoder(_ pass: GPURenderPassDescriptor) -> (any GPURenderEncoder)?
    func makeBlitEncoder() -> (any GPUBlitEncoder)?
    /// Runs once the GPU has finished the buffer's commands, on a thread of
    /// the backend's choosing.
    func addCompletedHandler(_ handler: @escaping @Sendable () -> Void)
    func commit()
    func waitUntilCompleted()
}

package protocol GPUCommandQueue: AnyObject {
    func makeCommandBuffer() -> (any GPUCommandBuffer)?
}

package enum GPUError: Error, Equatable {
    /// The library has no function of that name.
    case missingFunction(String)
    case pipelineCreationFailed(String)
}

package protocol GPUDevice: AnyObject {
    var features: GPUDeviceFeatures { get }

    func supportsTextureSampleCount(_ count: Int) -> Bool
    func makeBuffer(length: Int, storage: GPUStorage) -> (any GPUBuffer)?
    func makeBuffer(bytes: UnsafeRawPointer, length: Int, storage: GPUStorage) -> (any GPUBuffer)?
    func makeTexture(_ descriptor: GPUTextureDescriptor) -> (any GPUTexture)?
    func makeSampler(_ descriptor: GPUSamplerDescriptor) -> (any GPUSampler)?
    func makeDepthStencilState(_ descriptor: GPUDepthStencilDescriptor) -> (any GPUDepthStencilState)?
    /// A pipeline of the device's shader library. Throws when the library
    /// lacks a function, or the backend refuses the combination.
    func makeRenderPipeline(_ descriptor: GPURenderPipelineDescriptor) throws -> any GPURenderPipeline
    func makeCommandQueue() -> (any GPUCommandQueue)?
}
