// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension GroundRelief {
    /// The heights' texture and the occlusion as Metal's, for the relief
    /// drawers still on Metal. They go when those drawers move.
    var texture: MTLTexture { terrain.texture }
    var occlusion: MTLTexture? { gpuOcclusion?.metalTexture }
}
