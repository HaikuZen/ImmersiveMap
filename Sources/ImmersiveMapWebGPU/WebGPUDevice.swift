// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import Synchronization

/// The GPU interface over WebGPU, through the command stream
/// (`WebGPUCommandStream.swift`): every object is a handle the host keeps
/// the WebGPU object under, and every call is a command the host runs when
/// a command buffer is committed. The device makes the objects, keeps the
/// commands that make and write them until the next commit, and hands each
/// commit's stream to its sink.
///
/// What WebGPU does differently, and where the backend makes up for it:
/// - The CPU maps no GPU memory: a `.shared` buffer's `contents()` is a copy
///   in the module's memory, uploaded at the next commit after it was asked
///   for (`GPUBuffer.contents`).
/// - A pipeline holds the state Metal sets while encoding: each draw binds
///   the variant its state needs (`GPURenderStateTracker`), made once a
///   variant per device.
/// - Nothing waits for the GPU: `waitUntilCompleted` returns at once, and
///   the completed handlers run when the host says a submission is done
///   (`commandBufferCompleted`).
package final class WebGPUDevice: GPUDevice, @unchecked Sendable {
    package let features: GPUDeviceFeatures
    private let sink: any WebGPUCommandSink

    private struct State {
        var nextHandle = WebGPUHandle.first
        var nextCommandBuffer: UInt32 = 1
        /// The commands that make and write resources, run before the next
        /// committed command buffer's.
        var pending = WebGPUCommandWriter()
        /// The shared buffers whose bytes were handed out since their last
        /// upload.
        var dirty: [UInt32: WebGPUBuffer] = [:]
        var variants: [GPURenderStateTracker.Variant: UInt32] = [:]
        var completedHandlers: [UInt32: [@Sendable () -> Void]] = [:]
    }

    private let state = Mutex(State())

    /// - Parameter features: what the host's WebGPU device offers of the
    ///   optional features the engine uses (`GPUDeviceFeatures`).
    package init(features: GPUDeviceFeatures, sink: any WebGPUCommandSink) {
        self.features = features
        self.sink = sink
    }

    // MARK: - GPUDevice

    package func supportsTextureSampleCount(_ count: Int) -> Bool {
        count == 1 || count == 4
    }

    package func makeBuffer(length: Int, storage: GPUStorage) -> (any GPUBuffer)? {
        guard length > 0 else { return nil }
        let handle = record { handle, writer in
            writer.command(.createBuffer)
            writer.word(handle)
            writer.word(Self.uploadLength(length))
        }
        return WebGPUBuffer(device: self, handle: handle, length: length)
    }

    package func makeBuffer(bytes: UnsafeRawPointer, length: Int, storage: GPUStorage) -> (any GPUBuffer)? {
        guard let buffer = makeBuffer(length: length, storage: storage) as? WebGPUBuffer else { return nil }
        buffer.memory.copyMemory(from: bytes, byteCount: length)
        state.withLock { state in
            Self.writeUpload(of: buffer, into: &state.pending)
        }
        return buffer
    }

    package func makeTexture(_ descriptor: GPUTextureDescriptor) -> (any GPUTexture)? {
        guard descriptor.width > 0, descriptor.height > 0 else { return nil }
        let handle = record { handle, writer in
            writer.command(.createTexture)
            writer.word(handle)
            writer.string(descriptor.webGPUJSON.text)
        }
        return WebGPUTexture(device: self, handle: handle, descriptor: descriptor)
    }

    package func makeSampler(_ descriptor: GPUSamplerDescriptor) -> (any GPUSampler)? {
        let handle = record { handle, writer in
            writer.command(.createSampler)
            writer.word(handle)
            writer.string(descriptor.webGPUJSON.text)
        }
        return WebGPUSampler(device: self, handle: handle)
    }

    package func makeDepthStencilState(_ descriptor: GPUDepthStencilDescriptor) -> (any GPUDepthStencilState)? {
        let handle = record { handle, writer in
            writer.command(.createDepthStencilState)
            writer.word(handle)
            writer.string(descriptor.webGPUJSON.text)
        }
        return WebGPUDepthStencilState(device: self, handle: handle, descriptor: descriptor)
    }

    /// Never throws: WebGPU makes a pipeline asynchronously and reports a
    /// missing function or a refused combination to the host, which logs
    /// it. The variants are made from it as draws need them.
    package func makeRenderPipeline(_ descriptor: GPURenderPipelineDescriptor) throws -> any GPURenderPipeline {
        let handle = record { handle, writer in
            writer.command(.createRenderPipeline)
            writer.word(handle)
            writer.string(descriptor.webGPUJSON.text)
        }
        return WebGPURenderPipeline(device: self, handle: handle, descriptor: descriptor)
    }

    package func makeCommandQueue() -> (any GPUCommandQueue)? {
        WebGPUCommandQueue(device: self)
    }

    // MARK: - The host's side

    /// The host's drawable for a frame, the canvas's current texture, which
    /// a pass names as `WebGPUHandle.canvas`.
    package func canvasTexture(format: GPUPixelFormat, width: Int, height: Int) -> any GPUTexture {
        WebGPUCanvasTexture(format: format, width: width, height: height)
    }

    /// Runs the completed handlers of a committed command buffer, called by
    /// the host once the queue has finished its work.
    package func commandBufferCompleted(_ id: UInt32) {
        let handlers = state.withLock { $0.completedHandlers.removeValue(forKey: id) } ?? []
        for handler in handlers {
            handler()
        }
    }

    // MARK: - For the objects

    /// A new handle, with the commands that make its object.
    private func record(_ body: (UInt32, inout WebGPUCommandWriter) -> Void) -> UInt32 {
        state.withLock { state in
            let handle = state.nextHandle
            state.nextHandle += 1
            body(handle, &state.pending)
            return handle
        }
    }

    func appendPending(_ body: (inout WebGPUCommandWriter) -> Void) {
        state.withLock { body(&$0.pending) }
    }

    func markDirty(_ buffer: WebGPUBuffer) {
        state.withLock { $0.dirty[buffer.handle] = buffer }
    }

    func release(_ handle: UInt32) {
        state.withLock { state in
            state.pending.command(.release)
            state.pending.word(handle)
        }
    }

    /// Releases a pipeline or a depth and stencil state, with every variant
    /// made from it: the cache names them by the object's identity, which a
    /// new object may take once this one is gone.
    func releaseVariantSource(_ handle: UInt32, identity: ObjectIdentifier) {
        state.withLock { state in
            let gone = state.variants.filter { $0.key.pipeline == identity || $0.key.depthStencil == identity }
            for (variant, variantHandle) in gone.sorted(by: { $0.value < $1.value }) {
                state.variants.removeValue(forKey: variant)
                state.pending.command(.release)
                state.pending.word(variantHandle)
            }
            state.pending.command(.release)
            state.pending.word(handle)
        }
    }

    /// The handle of the pipeline variant a draw needs, made the first time
    /// it is met.
    func variantHandle(_ variant: GPURenderStateTracker.Variant,
                       pipeline: WebGPURenderPipeline,
                       depthStencil: WebGPUDepthStencilState?) -> UInt32 {
        state.withLock { state in
            if let handle = state.variants[variant] {
                return handle
            }
            let handle = state.nextHandle
            state.nextHandle += 1
            state.variants[variant] = handle
            var writer = state.pending
            writer.command(.createPipelineVariant)
            writer.word(handle)
            writer.word(pipeline.handle)
            writer.word(depthStencil?.handle ?? WebGPUHandle.none)
            writer.word(variant.cullMode.webGPUWord)
            writer.word(variant.frontFacing.webGPUWord)
            writer.float(variant.depthBias.constant)
            writer.float(variant.depthBias.slopeScale)
            writer.float(variant.depthBias.clamp)
            writer.word(variant.depthClipMode.webGPUWord)
            writer.word(variant.topology.webGPUWord)
            state.pending = writer
            return handle
        }
    }

    func nextCommandBufferID() -> UInt32 {
        state.withLock { state in
            let id = state.nextCommandBuffer
            state.nextCommandBuffer += 1
            return id
        }
    }

    /// Hands the sink the pending resource commands, the uploads of every
    /// buffer written since, and the command buffer's commands.
    func commit(id: UInt32, commands: WebGPUCommandWriter, completedHandlers: [@Sendable () -> Void]) {
        // The written buffers leave the lock with this, and are let go of
        // after it: the last reference to a buffer the engine has dropped
        // may be the one held here, and its `deinit` takes the lock
        // (`release`), which on a page's one thread never comes free.
        var uploaded: [UInt32: WebGPUBuffer] = [:]
        let stream = state.withLock { state -> WebGPUCommandWriter in
            var stream = state.pending
            state.pending.removeAll()
            swap(&uploaded, &state.dirty)
            for handle in uploaded.keys.sorted() {
                Self.writeUpload(of: uploaded[handle]!, into: &stream)
            }
            stream.append(commands)
            stream.command(.submit)
            stream.word(id)
            if completedHandlers.isEmpty == false {
                state.completedHandlers[id] = completedHandlers
            }
            return stream
        }
        stream.bytes.withUnsafeBytes { sink.submit($0) }
    }

    /// WebGPU writes a buffer in multiples of 4 bytes: the buffer is made
    /// that long, and the upload carries the copy's padding.
    static func uploadLength(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    private static func writeUpload(of buffer: WebGPUBuffer, into writer: inout WebGPUCommandWriter) {
        writer.command(.writeBuffer)
        writer.word(buffer.handle)
        writer.word(0)
        writer.byteRun(buffer.memory, length: uploadLength(buffer.length))
    }
}

/// A buffer: its handle, and the copy of its bytes the CPU writes, which is
/// uploaded at the next commit after `contents()` handed it out.
package final class WebGPUBuffer: GPUBuffer, @unchecked Sendable {
    let device: WebGPUDevice
    package let handle: UInt32
    package let length: Int
    package var allocatedSize: Int { WebGPUDevice.uploadLength(length) }
    package var label: String?
    let memory: UnsafeMutableRawPointer

    init(device: WebGPUDevice, handle: UInt32, length: Int) {
        self.device = device
        self.handle = handle
        self.length = length
        let padded = WebGPUDevice.uploadLength(length)
        memory = UnsafeMutableRawPointer.allocate(byteCount: padded, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: padded)
    }

    deinit {
        device.release(handle)
        memory.deallocate()
    }

    package func contents() -> UnsafeMutableRawPointer {
        device.markDirty(self)
        return memory
    }
}

package final class WebGPUTexture: GPUTexture {
    let device: WebGPUDevice
    package let handle: UInt32
    let descriptor: GPUTextureDescriptor

    init(device: WebGPUDevice, handle: UInt32, descriptor: GPUTextureDescriptor) {
        self.device = device
        self.handle = handle
        self.descriptor = descriptor
    }

    deinit {
        device.release(handle)
    }

    package var width: Int { descriptor.width }
    package var height: Int { descriptor.height }
    package var arrayLength: Int { descriptor.arrayLength }
    package var format: GPUPixelFormat { descriptor.format }
    package var type: GPUTextureType { descriptor.type }

    package var allocatedSize: Int {
        var size = 0
        for level in 0 ..< max(descriptor.mipmapLevelCount, 1) {
            let levelWidth = max(descriptor.width >> level, 1)
            let levelHeight = max(descriptor.height >> level, 1)
            size += descriptor.format.webGPUByteCount(width: levelWidth, height: levelHeight)
        }
        return size * max(descriptor.arrayLength, 1) * max(descriptor.sampleCount, 1)
    }

    package func replace(x: Int, y: Int, width: Int, height: Int,
                         mipmapLevel: Int, slice: Int,
                         bytes: UnsafeRawPointer, bytesPerRow: Int) {
        let rows = descriptor.format.webGPURowCount(height: height)
        device.appendPending { writer in
            writer.command(.writeTexture)
            writer.word(handle)
            writer.word(x)
            writer.word(y)
            writer.word(width)
            writer.word(height)
            writer.word(mipmapLevel)
            writer.word(slice)
            writer.word(bytesPerRow)
            writer.byteRun(bytes, length: bytesPerRow * rows)
        }
    }
}

/// The host's drawable: no object of the backend's, named by
/// `WebGPUHandle.canvas`.
final class WebGPUCanvasTexture: GPUTexture {
    let format: GPUPixelFormat
    let width: Int
    let height: Int
    var arrayLength: Int { 1 }
    var type: GPUTextureType { .type2D }
    var allocatedSize: Int { format.webGPUByteCount(width: width, height: height) }

    init(format: GPUPixelFormat, width: Int, height: Int) {
        self.format = format
        self.width = width
        self.height = height
    }

    func replace(x _: Int, y _: Int, width _: Int, height _: Int,
                 mipmapLevel _: Int, slice _: Int,
                 bytes _: UnsafeRawPointer, bytesPerRow _: Int) {
        preconditionFailure("The canvas is drawn into, never written")
    }
}

package final class WebGPUSampler: GPUSampler {
    let device: WebGPUDevice
    let handle: UInt32

    init(device: WebGPUDevice, handle: UInt32) {
        self.device = device
        self.handle = handle
    }

    deinit {
        device.release(handle)
    }
}

package final class WebGPUDepthStencilState: GPUDepthStencilState {
    let device: WebGPUDevice
    let handle: UInt32
    let descriptor: GPUDepthStencilDescriptor

    init(device: WebGPUDevice, handle: UInt32, descriptor: GPUDepthStencilDescriptor) {
        self.device = device
        self.handle = handle
        self.descriptor = descriptor
    }

    deinit {
        device.releaseVariantSource(handle, identity: ObjectIdentifier(self))
    }
}

package final class WebGPURenderPipeline: GPURenderPipeline {
    let device: WebGPUDevice
    let handle: UInt32
    let descriptor: GPURenderPipelineDescriptor

    init(device: WebGPUDevice, handle: UInt32, descriptor: GPURenderPipelineDescriptor) {
        self.device = device
        self.handle = handle
        self.descriptor = descriptor
    }

    deinit {
        device.releaseVariantSource(handle, identity: ObjectIdentifier(self))
    }
}

extension GPUPixelFormat {
    /// The texels of one image of the size, in bytes. A combined depth and
    /// stencil format is counted at 8 bytes, what drivers allocate.
    func webGPUByteCount(width: Int, height: Int) -> Int {
        switch self {
        case .bgra8Unorm, .rgba8Unorm: return width * height * 4
        case .r8Unorm: return width * height
        case .r16Float, .r16Unorm, .depth16Unorm: return width * height * 2
        case .depth32FloatStencil8: return width * height * 8
        case let .astc(blockWidth, blockHeight):
            return ((width + blockWidth - 1) / blockWidth) * ((height + blockHeight - 1) / blockHeight) * 16
        }
    }

    /// The rows of bytes an image of the height takes: a block-compressed
    /// format's rows are rows of blocks.
    func webGPURowCount(height: Int) -> Int {
        if case let .astc(_, blockHeight) = self {
            return (height + blockHeight - 1) / blockHeight
        }
        return height
    }
}
