// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The encoder state a WebGPU pipeline holds and a Metal encoder sets as it
/// goes: which pipeline, which depth and stencil state, the cull mode, the
/// winding, the depth bias and depth clipping. The engine sets these one
/// call at a time, as Metal lets it. A backend whose pipelines hold them
/// (WebGPU) keeps this tracker per pass, and before each draw asks it for
/// the pipeline variant the draw needs, which it makes once and caches by
/// `Variant`. A draw that changes none of it binds nothing.
///
/// Making a WebGPU pipeline compiles its shaders, tens of milliseconds, and
/// a variant met first in the middle of a frame stalls that frame. So the
/// backend makes the variants it knows of before the first frame: the
/// `Variant` values are plain data a backend can keep between launches,
/// by the descriptors behind their pipelines, and prepare ahead.
package struct GPURenderStateTracker {
    /// Everything a WebGPU pipeline is made from beyond the engine's
    /// pipeline descriptor.
    package struct Variant: Hashable {
        package var pipeline: ObjectIdentifier
        package var depthStencil: ObjectIdentifier?
        package var cullMode: GPUCullMode
        package var frontFacing: GPUWinding
        package var depthBias: GPUDepthBias
        package var depthClipMode: GPUDepthClipMode
    }

    package enum DrawError: Error, Equatable {
        /// A draw before any pipeline was set.
        case noPipeline
    }

    private var pipeline: ObjectIdentifier?
    private var depthStencil: ObjectIdentifier?
    private var cullMode = GPUCullMode.none
    private var frontFacing = GPUWinding.clockwise
    private var depthBias = GPUDepthBias.none
    private var depthClipMode = GPUDepthClipMode.clip
    private var bound: Variant?

    /// A new pass's state, which is Metal's default: no culling, clockwise
    /// front faces, no bias, depth clipped.
    package init() {}

    package mutating func setPipeline(_ pipeline: AnyObject) {
        self.pipeline = ObjectIdentifier(pipeline)
    }

    package mutating func setDepthStencilState(_ state: AnyObject) {
        depthStencil = ObjectIdentifier(state)
    }

    package mutating func setCullMode(_ mode: GPUCullMode) { cullMode = mode }
    package mutating func setFrontFacing(_ winding: GPUWinding) { frontFacing = winding }
    package mutating func setDepthBias(_ bias: GPUDepthBias) { depthBias = bias }
    package mutating func setDepthClipMode(_ mode: GPUDepthClipMode) { depthClipMode = mode }

    /// The variant the next draw needs, and whether it differs from the one
    /// bound for the draw before, in which case the backend binds it.
    package mutating func variantForDraw() throws -> (variant: Variant, needsBinding: Bool) {
        guard let pipeline else {
            throw DrawError.noPipeline
        }
        let variant = Variant(pipeline: pipeline, depthStencil: depthStencil, cullMode: cullMode,
                              frontFacing: frontFacing, depthBias: depthBias, depthClipMode: depthClipMode)
        defer { bound = variant }
        return (variant, variant != bound)
    }
}
