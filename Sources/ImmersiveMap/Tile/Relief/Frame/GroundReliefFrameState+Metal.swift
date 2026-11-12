// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension GroundReliefFrameState {
    /// The frame's start on Metal's queue, for the render core still on
    /// Metal. It goes when the core moves.
    @discardableResult
    func beginFrame(commandQueue: MTLCommandQueue) -> MTLCommandBuffer? {
        beginFrame(commandQueue: MetalCommandQueue(commandQueue))?.metalCommandBuffer
    }
}
