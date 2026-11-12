// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapMetal
import Metal

extension ShadowCascadeAtlas {
    /// `depthFormat` for the caster pipelines and the attachments still
    /// made with Metal. Goes when the last of them moves onto the GPU
    /// interface.
    static var depthPixelFormat: MTLPixelFormat { depthFormat.metal }
}
