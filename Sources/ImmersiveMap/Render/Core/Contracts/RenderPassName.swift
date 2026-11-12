// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

enum RenderPassName: String, CaseIterable {
    case shadowMap
    case farShadowMap
    case groundShadowMask
    case world
    case postProcessing
    case overlay
}
