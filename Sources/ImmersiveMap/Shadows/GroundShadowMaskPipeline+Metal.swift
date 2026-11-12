// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension GroundShadowMaskPipeline {
    /// `format` for the mask attachment and its fallback, still made with
    /// Metal. Goes when the render core's attachments move onto the GPU
    /// interface.
    static var pixelFormat: MTLPixelFormat { format.metal }
}
