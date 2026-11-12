// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import Metal

// Back from the interface to Metal, for the code that has not moved yet
// and takes an interface object from code that has (the render core's
// resource registry, the debug overlay). The object must be the Metal
// backend's own.

extension GPUBuffer {
    package var metalBuffer: MTLBuffer {
        guard let buffer = self as? MetalBuffer else {
            preconditionFailure("\(type(of: self)) is not a Metal backend's buffer")
        }
        return buffer.buffer
    }
}

extension GPUTexture {
    package var metalTexture: MTLTexture {
        guard let texture = self as? MetalTexture else {
            preconditionFailure("\(type(of: self)) is not a Metal backend's texture")
        }
        return texture.texture
    }
}

extension GPURenderPipeline {
    package var metalPipeline: MTLRenderPipelineState {
        guard let pipeline = self as? MetalRenderPipeline else {
            preconditionFailure("\(type(of: self)) is not a Metal backend's pipeline")
        }
        return pipeline.pipeline
    }
}

extension GPUDepthStencilState {
    package var metalState: MTLDepthStencilState {
        guard let state = self as? MetalDepthStencilState else {
            preconditionFailure("\(type(of: self)) is not a Metal backend's depth stencil state")
        }
        return state.state
    }
}
