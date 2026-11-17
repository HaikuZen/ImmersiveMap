// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import QuartzCore

/// The color destination of one rendered frame.
///
/// The live path wraps a `CAMetalDrawable` (its texture plus the drawable to
/// present); the offscreen path wraps a caller-supplied texture and presents
/// nothing. Pass descriptor providers only ever read `texture`.
struct FrameRenderTarget {
    /// Color texture the drawable-bound passes render into.
    let texture: MTLTexture
    /// `texture` as the GPU interface's, for the pass descriptors. Nil for
    /// a colour format the interface has no name for, which the shared
    /// resources refuse at launch.
    let gpuTexture: (any GPUTexture)?
    /// Non-nil only on the live `CAMetalLayer` path; presented after commit.
    let drawable: CAMetalDrawable?

    init(texture: MTLTexture, drawable: CAMetalDrawable? = nil) {
        self.texture = texture
        self.gpuTexture = GPUPixelFormat(metal: texture.pixelFormat).map { MetalTexture(texture, format: $0) }
        self.drawable = drawable
    }

    init(drawable: CAMetalDrawable) {
        self.init(texture: drawable.texture, drawable: drawable)
    }
}
