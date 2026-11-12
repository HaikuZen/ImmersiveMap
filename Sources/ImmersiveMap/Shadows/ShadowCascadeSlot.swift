// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation

/// The two windows of the shadow map, each a slice of the texture array,
/// rendered by its own pass from its own light matrix
/// (`ShadowFrameState.lightProjectionView(for:)`) through its own caster
/// layer. The raw value is the slice, mirrored by `kShadowNearSlice` and
/// `kShadowFarSlice` in RenderUniforms.h.
enum ShadowCascadeSlot: Int, CaseIterable {
    /// The sharp window around the ground the camera looks at.
    case near = 0
    /// The coarse window reaching the ground beyond it. Fitted only when
    /// `ShadowSettings.farCoverageMeters` reaches past the near
    /// window (`ShadowFrameStateResolver.resolveInputs`).
    case far = 1

    /// The layer the casters of this window draw in.
    var casterLayer: RenderLayer {
        switch self {
        case .near: .shadowCasters
        case .far: .farShadowCasters
        }
    }

    /// The render pass that writes this window's slice.
    var passName: RenderPassName {
        switch self {
        case .near: .shadowMap
        case .far: .farShadowMap
        }
    }

    /// The window a caster layer draws into, nil for any other layer.
    init?(casterLayer: RenderLayer) {
        switch casterLayer {
        case .shadowCasters: self = .near
        case .farShadowCasters: self = .far
        default: return nil
        }
    }
}
