// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension GroundFogUniform {
    /// Binds the fog for the features that still draw with the render
    /// core's Metal encoder. Goes when the last of them moves onto the GPU
    /// interface.
    static func bind(_ uniform: GroundFogUniform, encoder: MTLRenderCommandEncoder) {
        bind(uniform, encoder: MetalRenderEncoder(encoder))
    }
}
