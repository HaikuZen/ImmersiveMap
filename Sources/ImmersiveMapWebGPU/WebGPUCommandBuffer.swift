// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

final class WebGPUCommandQueue: GPUCommandQueue {
    let device: WebGPUDevice

    init(device: WebGPUDevice) {
        self.device = device
    }

    func makeCommandBuffer() -> (any GPUCommandBuffer)? {
        WebGPUCommandBuffer(device: device, id: device.nextCommandBufferID())
    }
}

/// The commands of one submission, written into the stream as its encoders
/// encode them and handed to the device's sink on commit.
final class WebGPUCommandBuffer: GPUCommandBuffer {
    let device: WebGPUDevice
    let id: UInt32
    var label: String?
    var writer = WebGPUCommandWriter()
    private var completedHandlers: [@Sendable () -> Void] = []
    private var isCommitted = false

    init(device: WebGPUDevice, id: UInt32) {
        self.device = device
        self.id = id
    }

    func makeRenderEncoder(_ pass: GPURenderPassDescriptor) -> (any GPURenderEncoder)? {
        writer.command(.beginRenderPass)
        writer.word(pass.colorAttachments.count)
        for attachment in pass.colorAttachments {
            writer.word(Self.handle(of: attachment.texture))
            writer.word(attachment.resolveTexture.map(Self.handle(of:)) ?? WebGPUHandle.none)
            writer.word(attachment.load.webGPUWord)
            writer.word(attachment.store.webGPUWord)
            writer.float(attachment.clearColor.red)
            writer.float(attachment.clearColor.green)
            writer.float(attachment.clearColor.blue)
            writer.float(attachment.clearColor.alpha)
        }
        if let depth = pass.depthStencilAttachment {
            precondition(depth.resolveTexture == nil,
                         "WebGPU resolves colour alone: a depth resolve needs GPUDeviceFeatures.depthResolve")
            writer.word(1)
            writer.word(Self.handle(of: depth.texture))
            writer.word(depth.slice)
            writer.word(depth.load.webGPUWord)
            writer.word(depth.store.webGPUWord)
            writer.float(depth.clearDepth)
            writer.word(depth.clearStencil)
        } else {
            writer.word(0)
        }
        writer.string(pass.label ?? "")
        return WebGPURenderEncoder(commandBuffer: self)
    }

    func makeBlitEncoder() -> (any GPUBlitEncoder)? {
        WebGPUBlitEncoder(commandBuffer: self)
    }

    func addCompletedHandler(_ handler: @escaping @Sendable () -> Void) {
        completedHandlers.append(handler)
    }

    /// The host reports no error and no GPU time: the buffer succeeded, of
    /// unknown duration.
    func addCompletedHandler(reporting handler: @escaping @Sendable (GPUCommandBufferCompletion) -> Void) {
        completedHandlers.append { handler(GPUCommandBufferCompletion(succeeded: true, gpuDuration: nil)) }
    }

    func commit() {
        precondition(isCommitted == false, "A command buffer is committed once")
        isCommitted = true
        device.commit(id: id, commands: writer, completedHandlers: completedHandlers)
        writer.removeAll()
    }

    /// Returns at once: a WebGPU host runs the commands after the module's
    /// code returns to it, so nothing here can wait for them.
    func waitUntilCompleted() {}

    static func handle(of texture: any GPUTexture) -> UInt32 {
        if let texture = texture as? WebGPUTexture {
            return texture.handle
        }
        precondition(texture is WebGPUCanvasTexture, "A texture of another backend")
        return WebGPUHandle.canvas
    }

    static func handle(of buffer: (any GPUBuffer)?) -> UInt32 {
        guard let buffer else { return WebGPUHandle.none }
        guard let buffer = buffer as? WebGPUBuffer else {
            preconditionFailure("A buffer of another backend")
        }
        return buffer.handle
    }
}

/// A render pass's commands. The state Metal sets while encoding is kept
/// by the tracker, and each draw binds the pipeline variant it needs.
final class WebGPURenderEncoder: GPURenderEncoder {
    private let commandBuffer: WebGPUCommandBuffer
    private var tracker = GPURenderStateTracker()
    private var pipeline: WebGPURenderPipeline?
    private var depthStencil: WebGPUDepthStencilState?
    private var isEnded = false

    init(commandBuffer: WebGPUCommandBuffer) {
        self.commandBuffer = commandBuffer
    }

    private func write(_ body: (inout WebGPUCommandWriter) -> Void) {
        precondition(isEnded == false, "A call on an ended render encoder")
        body(&commandBuffer.writer)
    }

    func setPipeline(_ pipeline: any GPURenderPipeline) {
        guard let pipeline = pipeline as? WebGPURenderPipeline else {
            preconditionFailure("A pipeline of another backend")
        }
        self.pipeline = pipeline
        tracker.setPipeline(pipeline)
    }

    func setDepthStencilState(_ state: any GPUDepthStencilState) {
        guard let state = state as? WebGPUDepthStencilState else {
            preconditionFailure("A depth and stencil state of another backend")
        }
        depthStencil = state
        tracker.setDepthStencilState(state)
    }

    func setStencilReference(_ value: UInt32) {
        write { writer in
            writer.command(.setStencilReference)
            writer.word(value)
        }
    }

    func setCullMode(_ mode: GPUCullMode) { tracker.setCullMode(mode) }
    func setFrontFacing(_ winding: GPUWinding) { tracker.setFrontFacing(winding) }
    func setDepthBias(_ bias: GPUDepthBias) { tracker.setDepthBias(bias) }
    func setDepthClipMode(_ mode: GPUDepthClipMode) { tracker.setDepthClipMode(mode) }

    /// WebGPU draws no triangle edges (`GPUTriangleFillMode`): the debug
    /// views that ask for them show filled triangles.
    func setTriangleFillMode(_: GPUTriangleFillMode) {}

    func setViewport(_ viewport: GPUViewport) {
        write { writer in
            writer.command(.setViewport)
            writer.float(viewport.x)
            writer.float(viewport.y)
            writer.float(viewport.width)
            writer.float(viewport.height)
            writer.float(viewport.minDepth)
            writer.float(viewport.maxDepth)
        }
    }

    func setScissorRect(_ rect: GPUScissorRect) {
        write { writer in
            writer.command(.setScissorRect)
            writer.word(rect.x)
            writer.word(rect.y)
            writer.word(rect.width)
            writer.word(rect.height)
        }
    }

    private func setBuffer(_ stage: WebGPUStage, _ buffer: (any GPUBuffer)?, offset: Int, index: Int) {
        write { writer in
            writer.command(.setBuffer)
            writer.word(stage.rawValue)
            writer.word(index)
            writer.word(WebGPUCommandBuffer.handle(of: buffer))
            writer.word(offset)
        }
    }

    private func setBytes(_ stage: WebGPUStage, _ bytes: UnsafeRawPointer, length: Int, index: Int) {
        precondition(length <= 4096, "Constant data is at most 4 KiB")
        write { writer in
            writer.command(.setBytes)
            writer.word(stage.rawValue)
            writer.word(index)
            writer.byteRun(bytes, length: length)
        }
    }

    private func setTexture(_ stage: WebGPUStage, _ texture: (any GPUTexture)?, index: Int) {
        write { writer in
            writer.command(.setTexture)
            writer.word(stage.rawValue)
            writer.word(index)
            writer.word(texture.map(WebGPUCommandBuffer.handle(of:)) ?? WebGPUHandle.none)
        }
    }

    func setVertexBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int) {
        setBuffer(.vertex, buffer, offset: offset, index: index)
    }

    func setVertexBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        setBytes(.vertex, bytes, length: length, index: index)
    }

    func setVertexTexture(_ texture: (any GPUTexture)?, index: Int) {
        setTexture(.vertex, texture, index: index)
    }

    func setFragmentBuffer(_ buffer: (any GPUBuffer)?, offset: Int, index: Int) {
        setBuffer(.fragment, buffer, offset: offset, index: index)
    }

    func setFragmentBytes(_ bytes: UnsafeRawPointer, length: Int, index: Int) {
        setBytes(.fragment, bytes, length: length, index: index)
    }

    func setFragmentTexture(_ texture: (any GPUTexture)?, index: Int) {
        setTexture(.fragment, texture, index: index)
    }

    func setFragmentSampler(_ sampler: (any GPUSampler)?, index: Int) {
        let handle: UInt32
        if let sampler {
            guard let sampler = sampler as? WebGPUSampler else {
                preconditionFailure("A sampler of another backend")
            }
            handle = sampler.handle
        } else {
            handle = WebGPUHandle.none
        }
        write { writer in
            writer.command(.setSampler)
            writer.word(WebGPUStage.fragment.rawValue)
            writer.word(index)
            writer.word(handle)
        }
    }

    /// Binds the variant of the pipeline the draw's state needs, where it
    /// differs from the one bound for the draw before.
    private func bindVariant(for topology: GPUPrimitiveTopology) {
        let resolved: (variant: GPURenderStateTracker.Variant, needsBinding: Bool)
        do {
            resolved = try tracker.variantForDraw(topology: topology)
        } catch {
            preconditionFailure("A draw before any pipeline was set")
        }
        guard resolved.needsBinding, let pipeline else { return }
        let handle = commandBuffer.device.variantHandle(resolved.variant, pipeline: pipeline, depthStencil: depthStencil)
        write { writer in
            writer.command(.setPipelineVariant)
            writer.word(handle)
        }
    }

    func draw(_ topology: GPUPrimitiveTopology, vertexStart: Int, vertexCount: Int,
              instanceCount: Int, baseInstance: Int) {
        bindVariant(for: topology)
        write { writer in
            writer.command(.draw)
            writer.word(vertexStart)
            writer.word(vertexCount)
            writer.word(instanceCount)
            writer.word(baseInstance)
        }
    }

    func drawIndexed(_ topology: GPUPrimitiveTopology, indexCount: Int, indexType: GPUIndexType,
                     indexBuffer: any GPUBuffer, indexBufferOffset: Int,
                     instanceCount: Int, baseVertex: Int, baseInstance: Int) {
        bindVariant(for: topology)
        write { writer in
            writer.command(.drawIndexed)
            writer.word(indexType.webGPUWord)
            writer.word(indexCount)
            writer.word(WebGPUCommandBuffer.handle(of: indexBuffer))
            writer.word(indexBufferOffset)
            writer.word(instanceCount)
            writer.word(baseVertex)
            writer.word(baseInstance)
        }
    }

    func pushDebugGroup(_ name: String) {
        write { writer in
            writer.command(.pushDebugGroup)
            writer.string(name)
        }
    }

    func popDebugGroup() {
        write { writer in
            writer.command(.popDebugGroup)
        }
    }

    func endEncoding() {
        write { writer in
            writer.command(.endPass)
        }
        isEnded = true
    }
}

/// Copies outside any pass, in the command buffer's order.
final class WebGPUBlitEncoder: GPUBlitEncoder {
    private let commandBuffer: WebGPUCommandBuffer

    init(commandBuffer: WebGPUCommandBuffer) {
        self.commandBuffer = commandBuffer
    }

    func copy(from source: any GPUBuffer, sourceOffset: Int,
              to destination: any GPUBuffer, destinationOffset: Int, size: Int) {
        commandBuffer.writer.command(.copyBufferToBuffer)
        commandBuffer.writer.word(WebGPUCommandBuffer.handle(of: source))
        commandBuffer.writer.word(sourceOffset)
        commandBuffer.writer.word(WebGPUCommandBuffer.handle(of: destination))
        commandBuffer.writer.word(destinationOffset)
        commandBuffer.writer.word(size)
    }

    func copy(from source: any GPUBuffer, sourceOffset: Int, bytesPerRow: Int,
              to texture: any GPUTexture, slice: Int, mipmapLevel: Int,
              x: Int, y: Int, width: Int, height: Int) {
        commandBuffer.writer.command(.copyBufferToTexture)
        commandBuffer.writer.word(WebGPUCommandBuffer.handle(of: source))
        commandBuffer.writer.word(sourceOffset)
        commandBuffer.writer.word(bytesPerRow)
        commandBuffer.writer.word(WebGPUCommandBuffer.handle(of: texture))
        commandBuffer.writer.word(slice)
        commandBuffer.writer.word(mipmapLevel)
        commandBuffer.writer.word(x)
        commandBuffer.writer.word(y)
        commandBuffer.writer.word(width)
        commandBuffer.writer.word(height)
    }

    func copy(from source: any GPUTexture, slice: Int, mipmapLevel: Int, x: Int, y: Int,
              to destination: any GPUTexture, destinationSlice: Int, destinationMipmapLevel: Int,
              destinationX: Int, destinationY: Int, width: Int, height: Int) {
        commandBuffer.writer.command(.copyTextureToTexture)
        commandBuffer.writer.word(WebGPUCommandBuffer.handle(of: source))
        commandBuffer.writer.word(slice)
        commandBuffer.writer.word(mipmapLevel)
        commandBuffer.writer.word(x)
        commandBuffer.writer.word(y)
        commandBuffer.writer.word(WebGPUCommandBuffer.handle(of: destination))
        commandBuffer.writer.word(destinationSlice)
        commandBuffer.writer.word(destinationMipmapLevel)
        commandBuffer.writer.word(destinationX)
        commandBuffer.writer.word(destinationY)
        commandBuffer.writer.word(width)
        commandBuffer.writer.word(height)
    }

    func generateMipmaps(for texture: any GPUTexture) {
        commandBuffer.writer.command(.generateMipmaps)
        commandBuffer.writer.word(WebGPUCommandBuffer.handle(of: texture))
    }

    func endEncoding() {}
}
