// Copyright (c) 2025-2026 Artem Bobkin.
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
    /// The gap to the stride, which the matrices align to 16, named: Swift would leave its bytes as whatever
    /// the stack held, and they would go to the GPU with the constant data.
    var _gap0: UInt32 = 0
}
