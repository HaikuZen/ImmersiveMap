// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import Metal

// The GPU interface over Metal: each class holds the Metal object and
// forwards to it. The Metal object stays reachable (`buffer`, `texture`,
// `encoder`), for the code that has not moved onto the interface yet and
// for what only Metal has (the IO queues that load the prepared tiles).
//
// An object handed to a Metal backend's method must be one of its own: a
// buffer from another backend is a programming error, and stops the
// process with a message that names it.

private func metalObject<Expected, Given>(_ given: Given, as _: Expected.Type) -> Expected {
    guard let object = given as? Expected else {
        preconditionFailure("A Metal backend was handed \(type(of: given)), which is not one of its \(Expected.self)")
    }
    return object
}

package final class MetalBuffer: GPUBuffer {
    package let buffer: MTLBuffer

    package init(_ buffer: MTLBuffer) {
        self.buffer = buffer
    }

    package var length: Int { buffer.length }

    package var label: String? {
        get { buffer.label }
        set { buffer.label = newValue }
    }

    package func contents() -> UnsafeMutableRawPointer {
        buffer.contents()
    }
}

package final class MetalTexture: GPUTexture {
    package let texture: MTLTexture
    package let format: GPUPixelFormat

    /// `format` is the interface's name for the texture's pixel format,
    /// which Metal's alone cannot give back for every texture.
    package init(_ texture: MTLTexture, format: GPUPixelFormat) {
        self.texture = texture
        self.format = format
    }

    package var width: Int { texture.width }
    package var height: Int { texture.height }
    package var arrayLength: Int { texture.arrayLength }

    package var type: GPUTextureType {
        switch texture.textureType {
        case .type2DArray: return .type2DArray
        case .type2DMultisample: return .type2DMultisample
        default: return .type2D
        }
    }

    package func replace(x: Int, y: Int, width: Int, height: Int,
                         mipmapLevel: Int, slice: Int,
                         bytes: UnsafeRawPointer, bytesPerRow: Int) {
        texture.replace(region: MTLRegionMake2D(x, y, width, height),
                        mipmapLevel: mipmapLevel,
                        slice: slice,
                        withBytes: bytes,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: texture.textureType == .type2DArray ? bytesPerRow * height : 0)
    }
}

package final class MetalSampler: GPUSampler {
    package let sampler: MTLSamplerState

    package init(_ sampler: MTLSamplerState) {
        self.sampler = sampler
    }
}

package final class MetalDepthStencilState: GPUDepthStencilState {
    package let state: MTLDepthStencilState

    package init(_ state: MTLDepthStencilState) {
        self.state = state
    }
}

package final class MetalRenderPipeline: GPURenderPipeline {
    package let pipeline: MTLRenderPipelineState

    package init(_ pipeline: MTLRenderPipelineState) {
        self.pipeline = pipeline
    }
}

package final class MetalRenderEncoder: GPURenderEncoder {
    package let encoder: MTLRenderCommandEncoder

    package init(_ encoder: MTLRenderCommandEncoder) {
        self.encoder = encoder
    }

    package func setPipeline(_ pipeline: any GPURenderPipeline) {
        encoder.setRenderPipelineState(metalObject(pipeline, as: MetalRenderPipeline.self).pipeline)
    }

    package func setDepthStencilState(_ state: any GPUDepthStencilState) {
        encoder.setDepthStencilState(metalObject(state, as: MetalDepthStencilState.self).state)
    }

    package func setStencilReference(_ value: UInt32) { encoder.setStencilReferenceValue(value) }
    package func setCullMode(_ mode: GPUCullMode) { encoder.setCullMode(mode.metal) }
    package func setFrontFacing(_ winding: GPUWinding) { encoder.setFrontFacing(winding.metal) }

    package func setDepthBias(_ bias: GPUDepthBias) {
        encoder.setDepthBias(bias.constant, slopeScale: bias.slopeScale, clamp: bias.clamp)
    }

    package func setDepthClipMode(_ mode: GPUDepthClipMode) { encoder.setDepthClipMode(mode.metal) }
    package func setTriangleFillMode(_ mode: GPUTriangleFillMode) { encoder.setTriangleFillMode(mode.metal) }

    package func setViewport(_ viewport: GPUViewport) {
        encoder.setViewport(MTLViewport(originX: viewport.x, originY: viewport.y,
                                        width: viewport.width, height: viewport.height,
                                        znear: viewport.minDepth, zfar: viewport.maxDepth))
    }

    package func setScissorRect(_ rect: GPUScissorRect) {
        encoder.setScissorRect(MTLScissorRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    package func setVertexBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int) {
        encoder.setVertexBuffer(buffer.map { metalObject($0, as: MetalBuffer.self).buffer }, offset: offset, index: index)
    }

    package func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        encoder.setVertexBytes(bytes, length: length, index: index)
    }

    package func setVertexTexture(_ texture: (any GPUTexture)?, index: Int) {
        encoder.setVertexTexture(texture.map { metalObject($0, as: MetalTexture.self).texture }, index: index)
    }

    package func setFragmentBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int) {
        encoder.setFragmentBuffer(buffer.map { metalObject($0, as: MetalBuffer.self).buffer }, offset: offset, index: index)
    }

    package func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        encoder.setFragmentBytes(bytes, length: length, index: index)
    }

    package func setFragmentTexture(_ texture: (any GPUTexture)?, index: Int) {
        encoder.setFragmentTexture(texture.map { metalObject($0, as: MetalTexture.self).texture }, index: index)
    }

    package func setFragmentSampler(_ sampler: (any GPUSampler)?, index: Int) {
        encoder.setFragmentSamplerState(sampler.map { metalObject($0, as: MetalSampler.self).sampler }, index: index)
    }

    package func draw(_ topology: GPUPrimitiveTopology, vertexStart: Int, vertexCount: Int,
                      instanceCount: Int, baseInstance: Int) {
        encoder.drawPrimitives(type: topology.metal, vertexStart: vertexStart, vertexCount: vertexCount,
                               instanceCount: instanceCount, baseInstance: baseInstance)
    }

    package func drawIndexed(_ topology: GPUPrimitiveTopology, indexCount: Int, indexType: GPUIndexType,
                             indexBuffer: any GPUBuffer, indexBufferOffset: Int,
                             instanceCount: Int, baseVertex: Int, baseInstance: Int) {
        encoder.drawIndexedPrimitives(type: topology.metal, indexCount: indexCount, indexType: indexType.metal,
                                      indexBuffer: metalObject(indexBuffer, as: MetalBuffer.self).buffer,
                                      indexBufferOffset: indexBufferOffset, instanceCount: instanceCount,
                                      baseVertex: baseVertex, baseInstance: baseInstance)
    }

    package func pushDebugGroup(_ name: String) { encoder.pushDebugGroup(name) }
    package func popDebugGroup() { encoder.popDebugGroup() }
    package func endEncoding() { encoder.endEncoding() }
}

package final class MetalBlitEncoder: GPUBlitEncoder {
    package let encoder: MTLBlitCommandEncoder

    package init(_ encoder: MTLBlitCommandEncoder) {
        self.encoder = encoder
    }

    package func copy(from source: any GPUBuffer, sourceOffset: Int,
                      to destination: any GPUBuffer, destinationOffset: Int, size: Int) {
        encoder.copy(from: metalObject(source, as: MetalBuffer.self).buffer, sourceOffset: sourceOffset,
                     to: metalObject(destination, as: MetalBuffer.self).buffer, destinationOffset: destinationOffset,
                     size: size)
    }

    package func copy(from source: any GPUBuffer, sourceOffset: Int, bytesPerRow: Int,
                      to texture: any GPUTexture, slice: Int, mipmapLevel: Int,
                      x: Int, y: Int, width: Int, height: Int) {
        encoder.copy(from: metalObject(source, as: MetalBuffer.self).buffer,
                     sourceOffset: sourceOffset,
                     sourceBytesPerRow: bytesPerRow,
                     sourceBytesPerImage: bytesPerRow * height,
                     sourceSize: MTLSize(width: width, height: height, depth: 1),
                     to: metalObject(texture, as: MetalTexture.self).texture,
                     destinationSlice: slice,
                     destinationLevel: mipmapLevel,
                     destinationOrigin: MTLOrigin(x: x, y: y, z: 0))
    }

    package func generateMipmaps(for texture: any GPUTexture) {
        encoder.generateMipmaps(for: metalObject(texture, as: MetalTexture.self).texture)
    }

    package func endEncoding() { encoder.endEncoding() }
}

package final class MetalCommandBuffer: GPUCommandBuffer {
    package let commandBuffer: MTLCommandBuffer

    package init(_ commandBuffer: MTLCommandBuffer) {
        self.commandBuffer = commandBuffer
    }

    package var label: String? {
        get { commandBuffer.label }
        set { commandBuffer.label = newValue }
    }

    package func makeRenderEncoder(_ pass: GPURenderPassDescriptor) -> (any GPURenderEncoder)? {
        let descriptor = MTLRenderPassDescriptor()
        for (index, attachment) in pass.colorAttachments.enumerated() {
            let color = descriptor.colorAttachments[index]!
            color.texture = metalObject(attachment.texture, as: MetalTexture.self).texture
            color.resolveTexture = attachment.resolveTexture.map { metalObject($0, as: MetalTexture.self).texture }
            color.loadAction = attachment.load.metal
            color.storeAction = attachment.store.metal
            color.clearColor = MTLClearColor(red: attachment.clearColor.red, green: attachment.clearColor.green,
                                             blue: attachment.clearColor.blue, alpha: attachment.clearColor.alpha)
        }
        if let depthStencil = pass.depthStencilAttachment {
            let texture = metalObject(depthStencil.texture, as: MetalTexture.self)
            descriptor.depthAttachment.texture = texture.texture
            descriptor.depthAttachment.loadAction = depthStencil.load.metal
            descriptor.depthAttachment.storeAction = depthStencil.store.metal
            descriptor.depthAttachment.clearDepth = depthStencil.clearDepth
            if texture.format.hasStencil {
                descriptor.stencilAttachment.texture = texture.texture
                descriptor.stencilAttachment.loadAction = depthStencil.load.metal
                descriptor.stencilAttachment.storeAction = depthStencil.store.metal
                descriptor.stencilAttachment.clearStencil = depthStencil.clearStencil
            }
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return nil
        }
        encoder.label = pass.label
        return MetalRenderEncoder(encoder)
    }

    package func makeBlitEncoder() -> (any GPUBlitEncoder)? {
        commandBuffer.makeBlitCommandEncoder().map(MetalBlitEncoder.init)
    }

    package func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
        commandBuffer.addCompletedHandler { _ in handler() }
    }

    package func commit() { commandBuffer.commit() }
    package func waitUntilCompleted() { commandBuffer.waitUntilCompleted() }
}

package final class MetalCommandQueue: GPUCommandQueue {
    package let queue: MTLCommandQueue

    package init(_ queue: MTLCommandQueue) {
        self.queue = queue
    }

    package func makeCommandBuffer() -> (any GPUCommandBuffer)? {
        queue.makeCommandBuffer().map(MetalCommandBuffer.init)
    }
}

/// The GPU interface over a Metal device and the shader library its
/// pipelines' functions come from. A device made without a library makes
/// buffers, textures and states, and refuses pipelines.
package final class MetalDevice: GPUDevice {
    package let device: MTLDevice
    package let library: MTLLibrary?

    package init(device: MTLDevice, library: MTLLibrary?) {
        self.device = device
        self.library = library
    }

    /// Metal clamps depth and draws triangle edges on every device. ASTC is
    /// on Apple's own GPUs, not on the Intel and AMD ones of older Macs.
    package var features: GPUDeviceFeatures {
        var features: GPUDeviceFeatures = [.depthClamp, .triangleEdges]
        if device.supportsFamily(.apple2) {
            features.insert(.astc)
        }
        return features
    }

    package func supportsTextureSampleCount(_ count: Int) -> Bool {
        device.supportsTextureSampleCount(count)
    }

    package func makeBuffer(length: Int, storage: GPUStorage) -> (any GPUBuffer)? {
        device.makeBuffer(length: length, options: Self.bufferOptions(storage)).map(MetalBuffer.init)
    }

    package func makeBuffer(bytes: UnsafeRawPointer, length: Int, storage: GPUStorage) -> (any GPUBuffer)? {
        device.makeBuffer(bytes: bytes, length: length, options: Self.bufferOptions(storage)).map(MetalBuffer.init)
    }

    private static func bufferOptions(_ storage: GPUStorage) -> MTLResourceOptions {
        storage == .shared ? .storageModeShared : .storageModePrivate
    }

    package func makeTexture(_ descriptor: GPUTextureDescriptor) -> (any GPUTexture)? {
        let metal = MTLTextureDescriptor()
        metal.textureType = descriptor.type.metal
        metal.pixelFormat = descriptor.format.metal
        metal.width = descriptor.width
        metal.height = descriptor.height
        metal.arrayLength = descriptor.arrayLength
        metal.mipmapLevelCount = descriptor.mipmapLevelCount
        metal.sampleCount = descriptor.sampleCount
        metal.usage = descriptor.usage.metal
        metal.storageMode = textureStorageMode(descriptor.storage)
        return device.makeTexture(descriptor: metal).map { MetalTexture($0, format: descriptor.format) }
    }

    /// A texture the CPU writes is shared where the GPU and the CPU share
    /// memory, and managed on a Mac whose GPU has its own.
    private func textureStorageMode(_ storage: GPUStorage) -> MTLStorageMode {
        switch storage {
        case .private:
            return .private
        case .shared:
            #if os(macOS)
            return device.hasUnifiedMemory ? .shared : .managed
            #else
            return .shared
            #endif
        }
    }

    package func makeSampler(_ descriptor: GPUSamplerDescriptor) -> (any GPUSampler)? {
        let metal = MTLSamplerDescriptor()
        metal.sAddressMode = descriptor.addressModeU.metal
        metal.tAddressMode = descriptor.addressModeV.metal
        metal.magFilter = descriptor.magFilter.metalMinMag
        metal.minFilter = descriptor.minFilter.metalMinMag
        metal.mipFilter = descriptor.mipFilter.metalMip
        metal.maxAnisotropy = descriptor.maxAnisotropy
        return device.makeSamplerState(descriptor: metal).map(MetalSampler.init)
    }

    package func makeDepthStencilState(_ descriptor: GPUDepthStencilDescriptor) -> (any GPUDepthStencilState)? {
        let metal = MTLDepthStencilDescriptor()
        metal.depthCompareFunction = descriptor.depthCompare.metal
        metal.isDepthWriteEnabled = descriptor.depthWriteEnabled
        metal.frontFaceStencil = descriptor.frontStencil.map(Self.stencil)
        metal.backFaceStencil = descriptor.backStencil.map(Self.stencil)
        return device.makeDepthStencilState(descriptor: metal).map(MetalDepthStencilState.init)
    }

    private static func stencil(_ face: GPUStencilFaceState) -> MTLStencilDescriptor {
        let metal = MTLStencilDescriptor()
        metal.stencilCompareFunction = face.compare.metal
        metal.stencilFailureOperation = face.stencilFailure.metal
        metal.depthFailureOperation = face.depthFailure.metal
        metal.depthStencilPassOperation = face.pass.metal
        metal.readMask = face.readMask
        metal.writeMask = face.writeMask
        return metal
    }

    package func makeRenderPipeline(_ descriptor: GPURenderPipelineDescriptor) throws -> any GPURenderPipeline {
        let metal = MTLRenderPipelineDescriptor()
        metal.label = descriptor.label
        metal.vertexFunction = try function(descriptor.vertexFunction)
        metal.fragmentFunction = try descriptor.fragmentFunction.map(function)
        if let layout = descriptor.vertexLayout {
            let vertexDescriptor = MTLVertexDescriptor()
            for (index, attribute) in layout.attributes {
                vertexDescriptor.attributes[index].format = attribute.format.metal
                vertexDescriptor.attributes[index].offset = attribute.offset
                vertexDescriptor.attributes[index].bufferIndex = attribute.bufferIndex
            }
            for (index, stride) in layout.strides {
                vertexDescriptor.layouts[index].stride = stride
                vertexDescriptor.layouts[index].stepFunction = .perVertex
            }
            metal.vertexDescriptor = vertexDescriptor
        }
        for (index, target) in descriptor.colorTargets.enumerated() {
            let color = metal.colorAttachments[index]!
            color.pixelFormat = target.format.metal
            color.writeMask = target.writesColor ? .all : []
            if let blend = target.blend {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = blend.color.source.metal
                color.destinationRGBBlendFactor = blend.color.destination.metal
                color.rgbBlendOperation = blend.color.operation.metal
                color.sourceAlphaBlendFactor = blend.alpha.source.metal
                color.destinationAlphaBlendFactor = blend.alpha.destination.metal
                color.alphaBlendOperation = blend.alpha.operation.metal
            }
        }
        if let depthStencilFormat = descriptor.depthStencilFormat {
            metal.depthAttachmentPixelFormat = depthStencilFormat.metal
            if depthStencilFormat.hasStencil {
                metal.stencilAttachmentPixelFormat = depthStencilFormat.metal
            }
        }
        metal.rasterSampleCount = descriptor.sampleCount
        metal.inputPrimitiveTopology = descriptor.topology.metalClass
        do {
            return MetalRenderPipeline(try device.makeRenderPipelineState(descriptor: metal))
        } catch {
            throw GPUError.pipelineCreationFailed("\(descriptor.label ?? descriptor.vertexFunction.name): \(error)")
        }
    }

    private func function(_ shader: GPUShaderFunction) throws -> MTLFunction {
        guard let library else {
            throw GPUError.missingFunction("\(shader.name): the device was made without a shader library")
        }
        guard shader.constants.isEmpty == false else {
            guard let function = library.makeFunction(name: shader.name) else {
                throw GPUError.missingFunction(shader.name)
            }
            return function
        }
        let values = MTLFunctionConstantValues()
        for (index, constant) in shader.constants {
            switch constant {
            case .bool(var value):
                values.setConstantValue(&value, type: .bool, index: index)
            case .int32(var value):
                values.setConstantValue(&value, type: .int, index: index)
            case .uint32(var value):
                values.setConstantValue(&value, type: .uint, index: index)
            case .float(var value):
                values.setConstantValue(&value, type: .float, index: index)
            }
        }
        do {
            return try library.makeFunction(name: shader.name, constantValues: values)
        } catch {
            throw GPUError.missingFunction("\(shader.name): \(error)")
        }
    }

    package func makeCommandQueue() -> (any GPUCommandQueue)? {
        device.makeCommandQueue().map(MetalCommandQueue.init)
    }
}
