// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension FrameContext {
    /// The frame's command buffer as Metal's, for the features still on
    /// Metal. Goes when they move onto the GPU interface.
    var commandBuffer: MTLCommandBuffer? { gpuCommandBuffer?.metalCommandBuffer }
}
