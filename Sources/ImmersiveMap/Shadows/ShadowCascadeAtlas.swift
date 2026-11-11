// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// Format of the shadow map: one square depth texture array with a slice
/// per cascade (`ShadowCascadeSlot`), each slice written by its own caster
/// pass and compared against by every receiver. Shared by the caster
/// pipelines, the attachment store and the resolver's UV math so they can
/// never disagree.
///
/// Two windows, not a cascade set and not one: the near window is fitted to
/// a disc of `ShadowSettings.nearCoverageMeters` at the camera zoom for
/// the shadows the camera looks at, sharp, and the far window to a disc of
/// `farCoverageMeters` for the ground beyond it, the mountains
/// casting across a valley from kilometres away, at the same map size and
/// so coarser. A receiver reads the near window where it reaches and the far
/// one past it, blended over the near window's fade band
/// (`shadowCascadeBlend` in RenderUniforms.h), and the shadows end where the
/// far window's own band fades them out.
///
/// Each slice is the attachment of a plain, non-layered pass
/// (`depthAttachment.slice`): no `render_target_array_index`, no
/// `renderTargetArrayLength`, which the iOS Simulator does not implement.
/// Each slice is rendered again only when its own window went stale
/// (`ShadowMapReuseController`), so the near window following the camera
/// does not redraw the far one.
enum ShadowCascadeAtlas {
    /// 16 bits are enough: the projection is refit to a tight caster range
    /// with depth clamping, so the extra depth32Float precision bought nothing
    /// while doubling the map's memory and the bandwidth of every
    /// `sample_compare`.
    static let depthPixelFormat: MTLPixelFormat = .depth16Unorm
    /// Slices of the map: one per cascade.
    static let sliceCount = ShadowCascadeSlot.allCases.count
}

