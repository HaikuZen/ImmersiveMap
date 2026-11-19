// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

/// The color destination of one rendered frame: the texture the
/// drawable-bound passes render into, and how the frame reaches the screen.
///
/// The live path wraps the platform's drawable and presents it
/// (`FrameRenderTarget.drawable(_:)` on Apple's platforms, which presents a
/// `CAMetalDrawable` through Core Animation); the offscreen path wraps a
/// caller-supplied texture and presents nothing. Pass descriptor providers
/// only ever read `texture`.
struct FrameRenderTarget {
    /// Color texture the drawable-bound passes render into.
    let texture: any GPUTexture
    /// Commits the frame's command buffer with the frame on its way to the
    /// screen. Nil for an offscreen target: the frame loop then commits the
    /// buffer itself.
    let present: ((any GPUCommandBuffer) -> Void)?

    init(texture: any GPUTexture, present: ((any GPUCommandBuffer) -> Void)? = nil) {
        self.texture = texture
        self.present = present
    }
}
