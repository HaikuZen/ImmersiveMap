// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

// A GPU that draws nothing and keeps a log of what it was asked: for the
// tests of a feature's drawing, which check the calls a feature makes (its
// pipeline, its buffers and values, its draw) on any platform, with no GPU
// and no picture. The constant data a call passes is copied into the log,
// so a test reads the values the shader would have read.

/// One call on a recording encoder.
package enum RecordedCommand: Equatable {
    case setPipeline(GPURenderPipelineDescriptor)
    case setDepthStencilState(GPUDepthStencilDescriptor)
    case setStencilReference(UInt32)
    case setCullMode(GPUCullMode)
    case setFrontFacing(GPUWinding)
    case setDepthBias(GPUDepthBias)
    case setDepthClipMode(GPUDepthClipMode)
    case setTriangleFillMode(GPUTriangleFillMode)
    case setViewport(GPUViewport)
    case setScissorRect(GPUScissorRect)
    /// The buffer by its `RecordingBuffer.name`, nil for none.
    case setVertexBuffer(String?, offset: Int, index: Int)
    case setVertexBytes([UInt8], index: Int)
    case setVertexTexture(String?, index: Int)
    case setFragmentBuffer(String?, offset: Int, index: Int)
    case setFragmentBytes([UInt8], index: Int)
    case setFragmentTexture(String?, index: Int)
    case setFragmentSampler(GPUSamplerDescriptor?, index: Int)
    case draw(GPUPrimitiveTopology, vertexStart: Int, vertexCount: Int, instanceCount: Int, baseInstance: Int)
    case drawIndexed(GPUPrimitiveTopology, indexCount: Int, indexType: GPUIndexType, indexBuffer: String,
                     indexBufferOffset: Int, instanceCount: Int, baseVertex: Int, baseInstance: Int)
    case pushDebugGroup(String)
    case popDebugGroup
    case endEncoding
}

package final class RecordingBuffer: GPUBuffer {
    /// A name for the log: "buffer N", in the order the device made them.
    package let name: String
    package let storage: GPUStorage
    private let memory: UnsafeMutableRawBufferPointer

    init(name: String, length: Int, storage: GPUStorage) {
        self.name = name
        self.storage = storage
        memory = UnsafeMutableRawBufferPointer.allocate(byteCount: max(length, 1), alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 0)
        self.length = length
    }

    deinit {
        memory.deallocate()
    }

    package let length: Int

    package func contents() -> UnsafeMutableRawPointer {
        memory.baseAddress!
    }

    /// The buffer's bytes, as values of a type.
    package func values<Value>(as _: Value.Type) -> [Value] {
        let count = length / MemoryLayout<Value>.stride
        return (0 ..< count).map { memory.load(fromByteOffset: $0 * MemoryLayout<Value>.stride, as: Value.self) }
    }
}

package final class RecordingTexture: GPUTexture {
    package let name: String
    package let descriptor: GPUTextureDescriptor
    /// The regions written with `replace`, in order.
    package private(set) var replacedRegions: [(x: Int, y: Int, width: Int, height: Int, slice: Int)] = []

    init(name: String, descriptor: GPUTextureDescriptor) {
        self.name = name
        self.descriptor = descriptor
    }

    package var width: Int { descriptor.width }
    package var height: Int { descriptor.height }
    package var arrayLength: Int { descriptor.arrayLength }
    package var format: GPUPixelFormat { descriptor.format }
    package var type: GPUTextureType { descriptor.type }

    package func replace(x: Int, y: Int, width: Int, height: Int,
                         mipmapLevel _: Int, slice: Int,
                         bytes _: UnsafeRawPointer, bytesPerRow _: Int) {
        replacedRegions.append((x, y, width, height, slice))
    }
}

package final class RecordingSampler: GPUSampler {
    package let descriptor: GPUSamplerDescriptor
    init(_ descriptor: GPUSamplerDescriptor) { self.descriptor = descriptor }
}

package final class RecordingDepthStencilState: GPUDepthStencilState {
    package let descriptor: GPUDepthStencilDescriptor
    init(_ descriptor: GPUDepthStencilDescriptor) { self.descriptor = descriptor }
}

package final class RecordingRenderPipeline: GPURenderPipeline {
    package let descriptor: GPURenderPipelineDescriptor
    init(_ descriptor: GPURenderPipelineDescriptor) { self.descriptor = descriptor }
}

package final class RecordingRenderEncoder: GPURenderEncoder {
    package private(set) var commands: [RecordedCommand] = []

    package init() {}

    private func record(_ command: RecordedCommand) { commands.append(command) }

    private static func name(_ buffer: (any GPUBuffer)?) -> String? {
        buffer.map { ($0 as? RecordingBuffer)?.name ?? "\(type(of: $0))" }
    }

    private static func name(_ texture: (any GPUTexture)?) -> String? {
        texture.map { ($0 as? RecordingTexture)?.name ?? "\(type(of: $0))" }
    }

    private static func bytes(_ pointer: UnsafeRawPointer, _ length: Int) -> [UInt8] {
        Array(UnsafeRawBufferPointer(start: pointer, count: length))
    }

    package func setPipeline(_ pipeline: any GPURenderPipeline) {
        guard let recording = pipeline as? RecordingRenderPipeline else {
            preconditionFailure("a recording encoder was handed \(type(of: pipeline))")
        }
        record(.setPipeline(recording.descriptor))
    }

    package func setDepthStencilState(_ state: any GPUDepthStencilState) {
        guard let recording = state as? RecordingDepthStencilState else {
            preconditionFailure("a recording encoder was handed \(type(of: state))")
        }
        record(.setDepthStencilState(recording.descriptor))
    }

    package func setStencilReference(_ value: UInt32) { record(.setStencilReference(value)) }
    package func setCullMode(_ mode: GPUCullMode) { record(.setCullMode(mode)) }
    package func setFrontFacing(_ winding: GPUWinding) { record(.setFrontFacing(winding)) }
    package func setDepthBias(_ bias: GPUDepthBias) { record(.setDepthBias(bias)) }
    package func setDepthClipMode(_ mode: GPUDepthClipMode) { record(.setDepthClipMode(mode)) }
    package func setTriangleFillMode(_ mode: GPUTriangleFillMode) { record(.setTriangleFillMode(mode)) }
    package func setViewport(_ viewport: GPUViewport) { record(.setViewport(viewport)) }
    package func setScissorRect(_ rect: GPUScissorRect) { record(.setScissorRect(rect)) }

    package func setVertexBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int) {
        record(.setVertexBuffer(Self.name(buffer), offset: offset, index: index))
    }

    package func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        record(.setVertexBytes(Self.bytes(bytes, length), index: index))
    }

    package func setVertexTexture(_ texture: (any GPUTexture)?, index: Int) {
        record(.setVertexTexture(Self.name(texture), index: index))
    }

    package func setFragmentBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int) {
        record(.setFragmentBuffer(Self.name(buffer), offset: offset, index: index))
    }

    package func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        record(.setFragmentBytes(Self.bytes(bytes, length), index: index))
    }

    package func setFragmentTexture(_ texture: (any GPUTexture)?, index: Int) {
        record(.setFragmentTexture(Self.name(texture), index: index))
    }

    package func setFragmentSampler(_ sampler: (any GPUSampler)?, index: Int) {
        record(.setFragmentSampler((sampler as? RecordingSampler)?.descriptor, index: index))
    }

    package func draw(_ topology: GPUPrimitiveTopology, vertexStart: Int, vertexCount: Int,
                      instanceCount: Int, baseInstance: Int) {
        record(.draw(topology, vertexStart: vertexStart, vertexCount: vertexCount,
                     instanceCount: instanceCount, baseInstance: baseInstance))
    }

    package func drawIndexed(_ topology: GPUPrimitiveTopology, indexCount: Int, indexType: GPUIndexType,
                             indexBuffer: any GPUBuffer, indexBufferOffset: Int,
                             instanceCount: Int, baseVertex: Int, baseInstance: Int) {
        record(.drawIndexed(topology, indexCount: indexCount, indexType: indexType,
                            indexBuffer: Self.name(indexBuffer) ?? "", indexBufferOffset: indexBufferOffset,
                            instanceCount: instanceCount, baseVertex: baseVertex, baseInstance: baseInstance))
    }

    package func pushDebugGroup(_ name: String) { record(.pushDebugGroup(name)) }
    package func popDebugGroup() { record(.popDebugGroup) }
    package func endEncoding() { record(.endEncoding) }

    /// The constant data last set at a vertex index, as a value.
    package func vertexValue<Value>(at index: Int, as _: Value.Type) -> Value? {
        for command in commands.reversed() {
            if case let .setVertexBytes(bytes, at) = command, at == index,
               bytes.count >= MemoryLayout<Value>.size {
                return bytes.withUnsafeBytes { $0.loadUnaligned(as: Value.self) }
            }
        }
        return nil
    }

    /// The same at a fragment index.
    package func fragmentValue<Value>(at index: Int, as _: Value.Type) -> Value? {
        for command in commands.reversed() {
            if case let .setFragmentBytes(bytes, at) = command, at == index,
               bytes.count >= MemoryLayout<Value>.size {
                return bytes.withUnsafeBytes { $0.loadUnaligned(as: Value.self) }
            }
        }
        return nil
    }
}

package final class RecordingBlitEncoder: GPUBlitEncoder {
    package private(set) var copies = 0
    package private(set) var mipmapGenerations = 0
    package private(set) var ended = false

    package func copy(from _: any GPUBuffer, sourceOffset _: Int,
                      to _: any GPUBuffer, destinationOffset _: Int, size _: Int) { copies += 1 }
    package func copy(from _: any GPUBuffer, sourceOffset _: Int, bytesPerRow _: Int,
                      to _: any GPUTexture, slice _: Int, mipmapLevel _: Int,
                      x _: Int, y _: Int, width _: Int, height _: Int) { copies += 1 }
    package func generateMipmaps(for _: any GPUTexture) { mipmapGenerations += 1 }
    package func endEncoding() { ended = true }
}

package final class RecordingCommandBuffer: GPUCommandBuffer {
    package var label: String?
    package private(set) var renderEncoders: [RecordingRenderEncoder] = []
    package private(set) var passes: [GPURenderPassDescriptor] = []
    package private(set) var committed = false
    private var completedHandlers: [@Sendable () -> Void] = []

    package func makeRenderEncoder(_ pass: GPURenderPassDescriptor) -> (any GPURenderEncoder)? {
        let encoder = RecordingRenderEncoder()
        renderEncoders.append(encoder)
        passes.append(pass)
        return encoder
    }

    package func makeBlitEncoder() -> (any GPUBlitEncoder)? { RecordingBlitEncoder() }

    package func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
        completedHandlers.append(handler)
    }

    /// Commits and runs the completed handlers at once: the recording GPU
    /// finishes as soon as it is asked.
    package func commit() {
        committed = true
        let handlers = completedHandlers
        completedHandlers = []
        handlers.forEach { $0() }
    }

    package func waitUntilCompleted() {}
}

package final class RecordingCommandQueue: GPUCommandQueue {
    package private(set) var commandBuffers: [RecordingCommandBuffer] = []

    package func makeCommandBuffer() -> (any GPUCommandBuffer)? {
        let buffer = RecordingCommandBuffer()
        commandBuffers.append(buffer)
        return buffer
    }
}

/// A recording device. Its pipelines' functions are found in
/// `shaderFunctions` when it is set, and any name is taken when it is nil.
package final class RecordingGPUDevice: GPUDevice {
    package var features: GPUDeviceFeatures
    package var shaderFunctions: Set<String>?
    package private(set) var buffers: [RecordingBuffer] = []
    package private(set) var textures: [RecordingTexture] = []
    package private(set) var pipelines: [GPURenderPipelineDescriptor] = []

    package init(features: GPUDeviceFeatures = [.depthClamp, .triangleEdges, .astc],
                 shaderFunctions: Set<String>? = nil) {
        self.features = features
        self.shaderFunctions = shaderFunctions
    }

    package func supportsTextureSampleCount(_ count: Int) -> Bool { [1, 4].contains(count) }

    package func makeBuffer(length: Int, storage: GPUStorage) -> (any GPUBuffer)? {
        // Metal makes no buffer of no bytes, and the engine's code counts on it.
        guard length > 0 else { return nil }
        let buffer = RecordingBuffer(name: "buffer \(buffers.count)", length: length, storage: storage)
        buffers.append(buffer)
        return buffer
    }

    package func makeBuffer(bytes: UnsafeRawPointer, length: Int, storage: GPUStorage) -> (any GPUBuffer)? {
        guard let buffer = makeBuffer(length: length, storage: storage) else { return nil }
        buffer.contents().copyMemory(from: bytes, byteCount: length)
        return buffer
    }

    package func makeTexture(_ descriptor: GPUTextureDescriptor) -> (any GPUTexture)? {
        let texture = RecordingTexture(name: "texture \(textures.count)", descriptor: descriptor)
        textures.append(texture)
        return texture
    }

    package func makeSampler(_ descriptor: GPUSamplerDescriptor) -> (any GPUSampler)? {
        RecordingSampler(descriptor)
    }

    package func makeDepthStencilState(_ descriptor: GPUDepthStencilDescriptor) -> (any GPUDepthStencilState)? {
        RecordingDepthStencilState(descriptor)
    }

    package func makeRenderPipeline(_ descriptor: GPURenderPipelineDescriptor) throws -> any GPURenderPipeline {
        for function in [descriptor.vertexFunction] + (descriptor.fragmentFunction.map { [$0] } ?? []) {
            if let shaderFunctions, shaderFunctions.contains(function.name) == false {
                throw GPUError.missingFunction(function.name)
            }
        }
        pipelines.append(descriptor)
        return RecordingRenderPipeline(descriptor)
    }

    package func makeCommandQueue() -> (any GPUCommandQueue)? { RecordingCommandQueue() }
}
