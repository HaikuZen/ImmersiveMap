// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal
import QuartzCore

extension FrameRenderTarget {
    /// The live path: the display link's drawable, presented through Metal's
    /// own command buffer. Nil for a colour format the GPU interface has no
    /// name for, which the shared resources refuse at launch.
    static func drawable(_ drawable: CAMetalDrawable) -> FrameRenderTarget? {
        guard let format = GPUPixelFormat(metal: drawable.texture.pixelFormat) else { return nil }
        return FrameRenderTarget(texture: MetalTexture(drawable.texture, format: format)) { commandBuffer in
            let metalCommandBuffer = commandBuffer.metalCommandBuffer
            if drawable.layer.presentsWithTransaction {
                // Markers are on screen: commit, wait until the buffer is
                // scheduled, then present, so the drawable rides the current
                // CATransaction together with the marker view frames set right
                // after the frame (Apple's transaction-synced pattern).
                metalCommandBuffer.commit()
                metalCommandBuffer.waitUntilScheduled()
                drawable.present()
            } else {
                metalCommandBuffer.present(drawable)
                metalCommandBuffer.commit()
            }
        }
    }

    /// The offscreen path: a caller's Metal texture, presented nowhere.
    static func offscreen(_ texture: MTLTexture) -> FrameRenderTarget? {
        guard let format = GPUPixelFormat(metal: texture.pixelFormat) else { return nil }
        return FrameRenderTarget(texture: MetalTexture(texture, format: format))
    }
}
