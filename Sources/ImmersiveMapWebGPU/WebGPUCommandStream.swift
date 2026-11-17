// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The commands the WebGPU backend hands its host, one stream of them per
/// submission, decoded by the host in one call (`Web/ImmersiveMapWebGPU.js`
/// in the browser). A call from WebAssembly to JavaScript per GPU call would
/// be the main cost of a frame, so the backend never makes one: every call
/// on the interface appends to the stream, and the stream goes to the host
/// when a command buffer is committed.
///
/// The format, which the decoder reads word by word:
/// - Little-endian 32-bit words. A command is its opcode word and its
///   arguments, each a word: an unsigned integer, a signed integer or a
///   32-bit float, as the opcode says.
/// - A byte run is its length in a word, then the bytes, padded with zeros
///   to the next word. A string is a byte run of UTF-8.
/// - A GPU object is named by a handle, a nonzero word the backend gives it
///   when it is made; 0 is none. `WebGPUHandle.canvas` is the host's
///   drawable for the frame.
/// - Descriptors made once (a texture, a sampler, a depth and stencil
///   state, a pipeline) are JSON strings in WebGPU's own names
///   (`WebGPUConversions.swift`). What a frame repeats is binary.
/// - A shader stage's buffer, texture and sampler *i* are given as the
///   Metal index *i*: the host binds them by the WGSL rule (binding *i*,
///   16 + *i*, 32 + *i* of the stage's group), or a buffer as the vertex
///   buffer of slot *i* where the pipeline's layout reads one there.
package enum WebGPUOpcode: UInt32, CaseIterable, Sendable {
    // Resources, made and written outside any pass.
    /// handle, size in bytes.
    case createBuffer = 1
    /// handle, offset, bytes.
    case writeBuffer = 2
    /// handle, JSON descriptor.
    case createTexture = 3
    /// handle, x, y, width, height, mip level, slice, bytes per row, bytes.
    case writeTexture = 4
    /// handle, JSON descriptor.
    case createSampler = 5
    /// handle, JSON descriptor. No WebGPU object: the host keeps it for the
    /// pipeline variants that name it.
    case createDepthStencilState = 6
    /// handle, JSON descriptor in the manifest's shape
    /// (`Tools/WGSLCheck/pipelines.json`). No WebGPU object either: the
    /// variants are made from it.
    case createRenderPipeline = 7
    /// handle, pipeline handle, depth and stencil state handle or 0, cull
    /// mode, front face, depth bias (float), slope scale (float), bias clamp
    /// (float), depth clip mode, topology. The WebGPU pipeline a draw binds.
    case createPipelineVariant = 8
    /// handle. The object is gone on the Swift side.
    case release = 9

    // A command buffer's commands.
    /// color attachment count, then per attachment: texture, resolve texture
    /// or 0, load action, store action, clear red, green, blue, alpha
    /// (floats). Then 1 and the depth attachment's texture, load action,
    /// store action, clear depth (float), clear stencil, or 0 for none.
    /// Then the pass's label.
    case beginRenderPass = 20
    case endPass = 21
    /// pipeline variant handle.
    case setPipelineVariant = 22
    /// reference.
    case setStencilReference = 23
    /// x, y, width, height, min depth, max depth (floats).
    case setViewport = 24
    /// x, y, width, height.
    case setScissorRect = 25
    /// stage, index, buffer handle or 0, offset.
    case setBuffer = 26
    /// stage, index, bytes. Constant data, at most 4 KiB.
    case setBytes = 27
    /// stage, index, texture handle or 0.
    case setTexture = 28
    /// stage, index, sampler handle or 0.
    case setSampler = 29
    /// vertex start, vertex count, instance count, base instance.
    case draw = 30
    /// index type, index count, index buffer handle, index buffer offset,
    /// instance count, base vertex (signed), base instance.
    case drawIndexed = 31
    /// name.
    case pushDebugGroup = 32
    case popDebugGroup = 33
    /// source, source offset, destination, destination offset, size.
    case copyBufferToBuffer = 34
    /// source, source offset, bytes per row, texture, slice, mip level, x,
    /// y, width, height.
    case copyBufferToTexture = 35
    /// texture. WebGPU has no mipmap generation: the host draws the levels.
    case generateMipmaps = 36
    /// command buffer id. Ends the stream's commands for the queue.
    case submit = 37
    /// source, slice, mip level, x, y, destination, slice, mip level, x, y,
    /// width, height.
    case copyTextureToTexture = 38
}

/// The names the stream gives the interface's values as words.
package enum WebGPUStage: UInt32, Sendable {
    case vertex = 0
    case fragment = 1
}

package enum WebGPUHandle {
    /// None: an unset binding, no depth and stencil state.
    package static let none: UInt32 = 0
    /// The host's drawable of the frame (`WebGPUDevice.canvasTexture`).
    package static let canvas: UInt32 = 1
    /// The first handle the backend gives an object.
    package static let first: UInt32 = 2
}

extension GPULoadAction {
    var webGPUWord: UInt32 {
        switch self {
        case .dontCare: return 0
        case .load: return 1
        case .clear: return 2
        }
    }
}

extension GPUStoreAction {
    var webGPUWord: UInt32 {
        switch self {
        case .dontCare: return 0
        case .store: return 1
        case .multisampleResolve: return 2
        }
    }
}

extension GPUCullMode {
    var webGPUWord: UInt32 {
        switch self {
        case .none: return 0
        case .front: return 1
        case .back: return 2
        }
    }
}

extension GPUWinding {
    /// WebGPU's `frontFace`: 0 `cw`, 1 `ccw`.
    var webGPUWord: UInt32 { self == .clockwise ? 0 : 1 }
}

extension GPUDepthClipMode {
    /// 1 asks for `unclippedDepth`.
    var webGPUWord: UInt32 { self == .clip ? 0 : 1 }
}

extension GPUPrimitiveTopology {
    var webGPUWord: UInt32 {
        switch self {
        case .point: return 0
        case .line: return 1
        case .triangle: return 2
        case .triangleStrip: return 3
        }
    }
}

extension GPUIndexType {
    var webGPUWord: UInt32 { self == .uint16 ? 0 : 1 }
}

/// Appends commands in the stream's format.
package struct WebGPUCommandWriter: Sendable {
    package private(set) var bytes: [UInt8] = []

    package init() {}

    package var isEmpty: Bool { bytes.isEmpty }

    package mutating func command(_ opcode: WebGPUOpcode) {
        word(opcode.rawValue)
    }

    package mutating func word(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    package mutating func word(_ value: Int) {
        word(UInt32(truncatingIfNeeded: value))
    }

    package mutating func float(_ value: Float) {
        word(value.bitPattern)
    }

    package mutating func float(_ value: Double) {
        float(Float(value))
    }

    package mutating func byteRun(_ pointer: UnsafeRawPointer, length: Int) {
        word(length)
        bytes.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: length))
        pad()
    }

    package mutating func string(_ value: String) {
        let utf8 = Array(value.utf8)
        word(utf8.count)
        bytes.append(contentsOf: utf8)
        pad()
    }

    package mutating func append(_ other: WebGPUCommandWriter) {
        bytes.append(contentsOf: other.bytes)
    }

    package mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }

    private mutating func pad() {
        while bytes.count % 4 != 0 {
            bytes.append(0)
        }
    }
}

/// Where a submission's stream goes: the browser's decoder through a
/// WebAssembly import, or a test that reads it back.
package protocol WebGPUCommandSink: AnyObject, Sendable {
    /// Decodes and runs one submission's commands. The bytes are valid only
    /// for the call.
    func submit(_ stream: UnsafeRawBufferPointer)
}
