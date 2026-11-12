// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The values the engine describes its GPU work with, apart from any API:
// what the engine's Metal code uses today, and no more. A backend (Metal on
// Apple's platforms, WebGPU elsewhere) turns them into its own. Where a
// backend cannot honour a value, the type says so, so the engine code that
// asks for it can be found.

/// A texel format. The engine draws into `bgra8Unorm` and
/// `depth32FloatStencil8`, the shadow map into `depth16Unorm` (WebGPU's
/// `depth16unorm`), samples the rest, and reads the scene models'
/// textures as ASTC, which WebGPU has as an optional feature only
/// (`GPUDeviceFeatures.astc`).
package enum GPUPixelFormat: Hashable, Sendable {
    case bgra8Unorm
    case rgba8Unorm
    case r8Unorm
    case r16Float
    case depth32FloatStencil8
    case depth16Unorm
    /// ASTC, low dynamic range, by its block's width and height in texels.
    case astc(blockWidth: Int, blockHeight: Int)
}

package enum GPUTextureType: Hashable, Sendable {
    case type2D
    case type2DArray
    case type2DMultisample
}

/// What a texture is used for. Both may be set.
package struct GPUTextureUsage: OptionSet, Hashable, Sendable {
    package let rawValue: UInt8
    package init(rawValue: UInt8) { self.rawValue = rawValue }

    package static let shaderRead = GPUTextureUsage(rawValue: 1 << 0)
    package static let renderTarget = GPUTextureUsage(rawValue: 1 << 1)
}

/// Where a resource's memory lives: `shared` is written by the CPU and read
/// by the GPU, `private` is the GPU's alone and filled by a copy or a draw.
package enum GPUStorage: Hashable, Sendable {
    case shared
    case `private`
}

package struct GPUTextureDescriptor: Hashable, Sendable {
    package var type: GPUTextureType = .type2D
    package var format: GPUPixelFormat
    package var width: Int
    package var height: Int
    package var arrayLength: Int = 1
    package var mipmapLevelCount: Int = 1
    package var sampleCount: Int = 1
    package var usage: GPUTextureUsage = .shaderRead
    package var storage: GPUStorage = .private

    package init(format: GPUPixelFormat, width: Int, height: Int) {
        self.format = format
        self.width = width
        self.height = height
    }
}

package enum GPUAddressMode: Hashable, Sendable {
    case clampToEdge
    case `repeat`
}

package enum GPUFilter: Hashable, Sendable {
    case nearest
    case linear
}

package struct GPUSamplerDescriptor: Hashable, Sendable {
    package var addressModeU: GPUAddressMode = .clampToEdge
    package var addressModeV: GPUAddressMode = .clampToEdge
    package var magFilter: GPUFilter = .nearest
    package var minFilter: GPUFilter = .nearest
    package var mipFilter: GPUFilter = .nearest
    package var maxAnisotropy: Int = 1

    package init() {}
}

package enum GPUCompareFunction: Hashable, Sendable {
    case never, less, equal, lessEqual, greater, notEqual, greaterEqual, always
}

package enum GPUStencilOperation: Hashable, Sendable {
    case keep, zero, replace, incrementClamp, decrementClamp, invert, incrementWrap, decrementWrap
}

package struct GPUStencilFaceState: Hashable, Sendable {
    package var compare: GPUCompareFunction = .always
    package var stencilFailure: GPUStencilOperation = .keep
    package var depthFailure: GPUStencilOperation = .keep
    package var pass: GPUStencilOperation = .keep
    package var readMask: UInt32 = 0xFFFF_FFFF
    package var writeMask: UInt32 = 0xFFFF_FFFF

    package init() {}
}

package struct GPUDepthStencilDescriptor: Hashable, Sendable {
    package var depthCompare: GPUCompareFunction = .always
    package var depthWriteEnabled = false
    /// Nil: the stencil is neither tested nor written.
    package var frontStencil: GPUStencilFaceState?
    package var backStencil: GPUStencilFaceState?

    package init() {}
}

package enum GPUBlendFactor: Hashable, Sendable {
    case zero, one, sourceAlpha, oneMinusSourceAlpha, destinationColor
}

package enum GPUBlendOperation: Hashable, Sendable {
    case add
}

package struct GPUBlendComponent: Hashable, Sendable {
    package var source: GPUBlendFactor
    package var destination: GPUBlendFactor
    package var operation: GPUBlendOperation = .add

    package init(source: GPUBlendFactor, destination: GPUBlendFactor, operation: GPUBlendOperation = .add) {
        self.source = source
        self.destination = destination
        self.operation = operation
    }
}

package struct GPUColorTarget: Hashable, Sendable {
    package var format: GPUPixelFormat
    /// Nil: the fragment replaces what is there.
    package var blend: (color: GPUBlendComponent, alpha: GPUBlendComponent)?
    /// False: nothing is written to the target (a pass that only marks the
    /// stencil or the depth).
    package var writesColor = true

    package init(format: GPUPixelFormat) {
        self.format = format
    }

    package static func == (lhs: GPUColorTarget, rhs: GPUColorTarget) -> Bool {
        lhs.format == rhs.format && lhs.writesColor == rhs.writesColor
            && lhs.blend?.color == rhs.blend?.color && lhs.blend?.alpha == rhs.blend?.alpha
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(format)
        hasher.combine(writesColor)
        hasher.combine(blend?.color)
        hasher.combine(blend?.alpha)
    }
}

/// A vertex attribute's format. WebGPU has no three-component 8 or 16-bit
/// formats (`char3Normalized`, `short3`): a WebGPU backend reads them as
/// their four-component kin, which the buffer's stride already pads for.
package enum GPUVertexFormat: Hashable, Sendable {
    case float, float2, float3, float4
    case int
    case uchar
    case ushort
    case short
    case short3
    case char3Normalized
    /// WebGPU's `snorm8x4`.
    case char4Normalized
    case ushort2Normalized
    case uchar4Normalized
}

package struct GPUVertexAttribute: Hashable, Sendable {
    package var format: GPUVertexFormat
    package var offset: Int
    package var bufferIndex: Int

    package init(format: GPUVertexFormat, offset: Int, bufferIndex: Int) {
        self.format = format
        self.offset = offset
        self.bufferIndex = bufferIndex
    }
}

package struct GPUVertexLayout: Hashable, Sendable {
    /// By attribute index.
    package var attributes: [Int: GPUVertexAttribute] = [:]
    /// The stride of each vertex buffer, by buffer index. Every buffer
    /// steps once a vertex.
    package var strides: [Int: Int] = [:]

    package init() {}
}

/// A specialization constant of a shader function, by its index.
package enum GPUConstantValue: Hashable, Sendable {
    case bool(Bool)
    case int32(Int32)
    case uint32(UInt32)
    case float(Float)
}

/// A shader function of the backend's library, by name, specialized by
/// its constants.
package struct GPUShaderFunction: Hashable, Sendable {
    package var name: String
    package var constants: [Int: GPUConstantValue]

    package init(name: String, constants: [Int: GPUConstantValue] = [:]) {
        self.name = name
        self.constants = constants
    }
}

/// What a pipeline is made from. The state the engine changes while it
/// encodes (cull mode, winding, depth bias, depth clipping, the depth and
/// stencil state) is not here, as in Metal: it is set on the encoder. A
/// WebGPU backend, whose pipelines hold that state, makes a pipeline for each
/// combination it meets (`GPURenderStateTracker`).
package struct GPURenderPipelineDescriptor: Hashable, Sendable {
    package var label: String?
    package var vertexFunction: GPUShaderFunction
    package var fragmentFunction: GPUShaderFunction?
    package var vertexLayout: GPUVertexLayout?
    package var colorTargets: [GPUColorTarget]
    package var depthStencilFormat: GPUPixelFormat?
    package var sampleCount = 1
    /// What the vertex function draws. A WebGPU pipeline is made for one
    /// primitive topology.
    package var topology: GPUPrimitiveTopology = .triangle

    package init(vertexFunction: GPUShaderFunction,
                 fragmentFunction: GPUShaderFunction?,
                 colorTargets: [GPUColorTarget]) {
        self.vertexFunction = vertexFunction
        self.fragmentFunction = fragmentFunction
        self.colorTargets = colorTargets
    }
}

package enum GPUPrimitiveTopology: Hashable, Sendable {
    case point, line, triangle, triangleStrip
}

package enum GPUIndexType: Hashable, Sendable {
    case uint16, uint32

    package var byteCount: Int { self == .uint16 ? 2 : 4 }
}

package enum GPUCullMode: Hashable, Sendable {
    case none, front, back
}

package enum GPUWinding: Hashable, Sendable {
    case clockwise, counterClockwise
}

/// Whether fragments outside the depth range are clipped or clamped.
/// Clamping is an optional WebGPU feature (`GPUDeviceFeatures.depthClamp`).
package enum GPUDepthClipMode: Hashable, Sendable {
    case clip, clamp
}

/// Drawn filled, or as the triangles' edges. WebGPU has no edges mode: a
/// WebGPU backend draws filled, and the debug overlays that ask for edges
/// show filled triangles there.
package enum GPUTriangleFillMode: Hashable, Sendable {
    case fill, lines
}

package struct GPUDepthBias: Hashable, Sendable {
    package var constant: Float
    package var slopeScale: Float
    package var clamp: Float

    package init(constant: Float, slopeScale: Float, clamp: Float) {
        self.constant = constant
        self.slopeScale = slopeScale
        self.clamp = clamp
    }

    package static let none = GPUDepthBias(constant: 0, slopeScale: 0, clamp: 0)
}

package struct GPUViewport: Hashable, Sendable {
    package var x: Double, y: Double, width: Double, height: Double
    package var minDepth: Double = 0, maxDepth: Double = 1

    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct GPUScissorRect: Hashable, Sendable {
    package var x: Int, y: Int, width: Int, height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package enum GPULoadAction: Hashable, Sendable {
    case dontCare, load, clear
}

package enum GPUStoreAction: Hashable, Sendable {
    case dontCare, store, multisampleResolve
}

package struct GPUClearColor: Hashable, Sendable {
    package var red: Double, green: Double, blue: Double, alpha: Double

    package init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// What the device can do beyond what every backend has.
package struct GPUDeviceFeatures: OptionSet, Hashable, Sendable {
    package let rawValue: UInt8
    package init(rawValue: UInt8) { self.rawValue = rawValue }

    package static let astc = GPUDeviceFeatures(rawValue: 1 << 0)
    package static let depthClamp = GPUDeviceFeatures(rawValue: 1 << 1)
    package static let triangleEdges = GPUDeviceFeatures(rawValue: 1 << 2)
}
