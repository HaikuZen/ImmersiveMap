// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// The interface's values as WebGPU names them, one property per type, the
// counterpart of ImmersiveMapMetal's MetalConversions.swift. The WebGPU
// backend describes its pipelines with these, and the WGSL check builds the
// ported pipelines with them (WGSLPipelineManifestTests, Tools/WGSLCheck).

extension GPUVertexFormat {
    /// WebGPU's vertex format. WebGPU has no three-component 8 or 16-bit
    /// format: `short3` and `char3Normalized` are read as their
    /// four-component kin, the fourth component the next bytes of the
    /// vertex, which the shader leaves unread. An integer format reaches the
    /// shader as integers, never converted to float as Metal does.
    package var webGPU: String {
        switch self {
        case .float: return "float32"
        case .float2: return "float32x2"
        case .float3: return "float32x3"
        case .float4: return "float32x4"
        case .int: return "sint32"
        case .uchar: return "uint8"
        case .char: return "sint8"
        case .ushort: return "uint16"
        case .short: return "sint16"
        case .short3: return "sint16x4"
        case .char2Normalized: return "snorm8x2"
        case .char3Normalized: return "snorm8x4"
        case .char4Normalized: return "snorm8x4"
        case .ushort2Normalized: return "unorm16x2"
        case .ushort3Normalized: return "unorm16x4"
        case .uchar4Normalized: return "unorm8x4"
        }
    }

    /// The bytes WebGPU reads for the attribute, which must lie inside the
    /// vertex's stride: four for a three-component 8-bit format, eight for
    /// a three-component 16-bit one.
    package var webGPUByteCount: Int {
        switch self {
        case .uchar, .char: return 1
        case .ushort, .short, .char2Normalized: return 2
        case .float, .int, .char3Normalized, .char4Normalized, .ushort2Normalized, .uchar4Normalized: return 4
        case .float2, .short3, .ushort3Normalized: return 8
        case .float3: return 12
        case .float4: return 16
        }
    }
}

extension GPUPixelFormat {
    /// WebGPU's texture format. `depth32FloatStencil8` needs the device
    /// feature of the same name and ASTC needs `texture-compression-astc`,
    /// both optional in WebGPU.
    package var webGPU: String {
        switch self {
        case .bgra8Unorm: return "bgra8unorm"
        case .rgba8Unorm: return "rgba8unorm"
        case .r8Unorm: return "r8unorm"
        case .r16Float: return "r16float"
        case .depth32FloatStencil8: return "depth32float-stencil8"
        case .depth16Unorm: return "depth16unorm"
        case let .astc(blockWidth, blockHeight): return "astc-\(blockWidth)x\(blockHeight)-unorm"
        }
    }

    package var hasDepth: Bool {
        self == .depth32FloatStencil8 || self == .depth16Unorm
    }
}

extension GPUBlendFactor {
    package var webGPU: String {
        switch self {
        case .zero: return "zero"
        case .one: return "one"
        case .sourceAlpha: return "src-alpha"
        case .oneMinusSourceAlpha: return "one-minus-src-alpha"
        case .destinationColor: return "dst"
        }
    }
}

extension GPUBlendOperation {
    package var webGPU: String {
        switch self {
        case .add: return "add"
        }
    }
}

extension GPUCompareFunction {
    package var webGPU: String {
        switch self {
        case .never: return "never"
        case .less: return "less"
        case .equal: return "equal"
        case .lessEqual: return "less-equal"
        case .greater: return "greater"
        case .notEqual: return "not-equal"
        case .greaterEqual: return "greater-equal"
        case .always: return "always"
        }
    }
}

extension GPUPrimitiveTopology {
    package var webGPU: String {
        switch self {
        case .point: return "point-list"
        case .line: return "line-list"
        case .triangle: return "triangle-list"
        case .triangleStrip: return "triangle-strip"
        }
    }
}

extension GPUConstantValue {
    /// A pipeline constant as WebGPU passes one, a number: a bool is 0 or 1.
    package var webGPU: Double {
        switch self {
        case let .bool(value): return value ? 1 : 0
        case let .int32(value): return Double(value)
        case let .uint32(value): return Double(value)
        case let .float(value): return Double(value)
        }
    }
}

extension GPUVertexLayout {
    /// The layout's buffers by WebGPU vertex buffer slot, `nil` for a slot
    /// it does not name. A Metal buffer index the layout names is a vertex
    /// buffer slot on WebGPU, any other a binding of the stage's group.
    package var webGPUBuffers: [(arrayStride: Int, attributes: [(format: String, offset: Int, shaderLocation: Int)])?] {
        guard let last = strides.keys.max() else { return [] }
        return (0 ... last).map { slot in
            guard let stride = strides[slot] else { return nil }
            let slotAttributes = attributes
                .filter { $0.value.bufferIndex == slot }
                .sorted { $0.key < $1.key }
                .map { (format: $0.value.format.webGPU, offset: $0.value.offset, shaderLocation: $0.key) }
            return (arrayStride: stride, attributes: slotAttributes)
        }
    }
}
