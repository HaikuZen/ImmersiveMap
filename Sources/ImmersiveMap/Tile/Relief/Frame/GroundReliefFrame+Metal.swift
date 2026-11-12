// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension GroundReliefFrame {
    /// The occlusion fallback as Metal's, for the relief drawers still on
    /// Metal. It goes when they move.
    var occlusionFallbackTexture: MTLTexture? { gpuOcclusionFallbackTexture?.metalTexture }
}
