// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Mirrors `RoadLabelSceneDepthUniforms` in LabelTextCommon.h: the eye takes
/// 16 bytes on both sides, so the viewport follows at 144.
struct RoadLabelSceneDepthUniforms {
    var projectionView: simd_float4x4
    var inverseProjectionView: simd_float4x4
    var eye: SIMD3<Float>
    var viewportSize: SIMD2<Float>
    var enabled: UInt32
}
