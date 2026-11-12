// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapMetal
import Metal

extension FrameContextSharedState {
    /// `gpuSceneDepthTexture` as Metal's, for the render core, which keeps
    /// the world's depth with Metal. The same texture object is read back,
    /// so the pass plan tells it apart from the pass's own by identity.
    /// Goes when the render core moves onto the GPU interface.
    var sceneDepthTexture: MTLTexture? {
        get { gpuSceneDepthTexture?.metalTexture }
        set {
            gpuSceneDepthTexture = newValue.map {
                MetalTexture($0, format: GPUPixelFormat(metal: $0.pixelFormat) ?? .depth32FloatStencil8)
            }
        }
    }
}
