// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Bounds in asset space (before the Y-up to Z-up anchor conversion);
/// rotation-invariant radius/extent survive the conversion unchanged. The
/// box is the stored truth and the rest is derived from it, so sizing,
/// culling and hit-testing cannot disagree about how large a model is.
struct SceneModelBounds {
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    let center: SIMD3<Float>
    /// Bounding sphere of the box, the radius frustum culling uses.
    let radius: Float
    /// Longest edge of the box, what `fitDiameterMeters` is measured against.
    let maxExtent: Float

    init(minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        self.minimum = minimum
        self.maximum = maximum
        center = (minimum + maximum) * 0.5
        let extents = maximum - minimum
        radius = max(simd_length(extents) * 0.5, 1e-6)
        maxExtent = max(extents.max(), 1e-6)
    }
}
