// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import Metal

// The GPU interface's values as Metal's, one function per type, so the
// mapping is in one place and the tests can hold each to its Metal value.

extension GPUPixelFormat {
    /// `.invalid` for an ASTC block size Metal has no format for.
    package var metal: MTLPixelFormat {
        switch self {
        case .bgra8Unorm: return .bgra8Unorm
        case .rgba8Unorm: return .rgba8Unorm
        case .r8Unorm: return .r8Unorm
        case .r16Float: return .r16Float
        case .depth32FloatStencil8: return .depth32Float_stencil8
        case let .astc(blockWidth, blockHeight):
            switch (blockWidth, blockHeight) {
            case (4, 4): return .astc_4x4_ldr
            case (5, 5): return .astc_5x5_ldr
            case (6, 6): return .astc_6x6_ldr
            case (8, 8): return .astc_8x8_ldr
            case (10, 10): return .astc_10x10_ldr
            case (12, 12): return .astc_12x12_ldr
            default: return .invalid
            }
        }
    }

    var hasStencil: Bool { self == .depth32FloatStencil8 }
}

extension GPUTextureType {
    package var metal: MTLTextureType {
        switch self {
        case .type2D: return .type2D
        case .type2DArray: return .type2DArray
        case .type2DMultisample: return .type2DMultisample
        }
    }
}

extension GPUTextureUsage {
    package var metal: MTLTextureUsage {
        var usage: MTLTextureUsage = []
        if contains(.shaderRead) { usage.insert(.shaderRead) }
        if contains(.renderTarget) { usage.insert(.renderTarget) }
        return usage
    }
}

extension GPUCompareFunction {
    package var metal: MTLCompareFunction {
        switch self {
        case .never: return .never
        case .less: return .less
        case .equal: return .equal
        case .lessEqual: return .lessEqual
        case .greater: return .greater
        case .notEqual: return .notEqual
        case .greaterEqual: return .greaterEqual
        case .always: return .always
        }
    }
}

extension GPUStencilOperation {
    package var metal: MTLStencilOperation {
        switch self {
        case .keep: return .keep
        case .zero: return .zero
        case .replace: return .replace
        case .incrementClamp: return .incrementClamp
        case .decrementClamp: return .decrementClamp
        case .invert: return .invert
        case .incrementWrap: return .incrementWrap
        case .decrementWrap: return .decrementWrap
        }
    }
}

extension GPUBlendFactor {
    package var metal: MTLBlendFactor {
        switch self {
        case .zero: return .zero
        case .one: return .one
        case .sourceAlpha: return .sourceAlpha
        case .oneMinusSourceAlpha: return .oneMinusSourceAlpha
        case .destinationColor: return .destinationColor
        }
    }
}

extension GPUBlendOperation {
    package var metal: MTLBlendOperation {
        switch self {
        case .add: return .add
        }
    }
}

extension GPUVertexFormat {
    package var metal: MTLVertexFormat {
        switch self {
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        case .float4: return .float4
        case .int: return .int
        case .uchar: return .uchar
        case .ushort: return .ushort
        case .short: return .short
        case .short3: return .short3
        case .char3Normalized: return .char3Normalized
        case .ushort2Normalized: return .ushort2Normalized
        case .uchar4Normalized: return .uchar4Normalized
        }
    }
}

extension GPUAddressMode {
    package var metal: MTLSamplerAddressMode {
        switch self {
        case .clampToEdge: return .clampToEdge
        case .repeat: return .repeat
        }
    }
}

extension GPUFilter {
    package var metalMinMag: MTLSamplerMinMagFilter {
        self == .linear ? .linear : .nearest
    }

    package var metalMip: MTLSamplerMipFilter {
        self == .linear ? .linear : .nearest
    }
}

extension GPUPrimitiveTopology {
    package var metal: MTLPrimitiveType {
        switch self {
        case .point: return .point
        case .line: return .line
        case .triangle: return .triangle
        case .triangleStrip: return .triangleStrip
        }
    }

    package var metalClass: MTLPrimitiveTopologyClass {
        switch self {
        case .point: return .point
        case .line: return .line
        case .triangle, .triangleStrip: return .triangle
        }
    }
}

extension GPUIndexType {
    package var metal: MTLIndexType {
        self == .uint16 ? .uint16 : .uint32
    }
}

extension GPUCullMode {
    package var metal: MTLCullMode {
        switch self {
        case .none: return .none
        case .front: return .front
        case .back: return .back
        }
    }
}

extension GPUWinding {
    package var metal: MTLWinding {
        self == .clockwise ? .clockwise : .counterClockwise
    }
}

extension GPUDepthClipMode {
    package var metal: MTLDepthClipMode {
        self == .clip ? .clip : .clamp
    }
}

extension GPUTriangleFillMode {
    package var metal: MTLTriangleFillMode {
        self == .fill ? .fill : .lines
    }
}

extension GPULoadAction {
    package var metal: MTLLoadAction {
        switch self {
        case .dontCare: return .dontCare
        case .load: return .load
        case .clear: return .clear
        }
    }
}

extension GPUStoreAction {
    package var metal: MTLStoreAction {
        switch self {
        case .dontCare: return .dontCare
        case .store: return .store
        case .multisampleResolve: return .multisampleResolve
        }
    }
}
