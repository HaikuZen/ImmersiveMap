// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame parameters of the horizon layer; the layout mirrors `Horizon`
/// in Horizon.metal (pinned by `HorizonUniformLayoutTests`). The values are
/// resolved by `HorizonFrameResolver`; this is only their GPU shape.
///
/// A `SIMD3` aligns to 16, so a single `Float` after one leaves a gap
/// before the next, and the matrix and the stride leave two more. Every gap
/// is named as zeroed fields (`_gap0` to `_gap19`), so its bytes are zeros
/// and not whatever the stack held, which would go to the GPU with the
/// constant data: unread, but a WebGPU frame's stream would differ from run
/// to run. The fields' offsets are Metal's and WGSL's, gaps included.
struct HorizonUniform {
    /// The eye's local vertical.
    var up: SIMD3<Float>
    /// The edge's depression below the local horizontal, radians.
    var depression: Float
    var _gap0: Float = 0, _gap1: Float = 0, _gap2: Float = 0
    var center: SIMD3<Float>
    var sunInfluence: Float
    var _gap3: Float = 0, _gap4: Float = 0, _gap5: Float = 0
    var light: SIMD3<Float>
    var skyStrength: Float
    var _gap6: Float = 0, _gap7: Float = 0, _gap8: Float = 0
    var tint: SIMD3<Float>
    var whitenWeight: Float
    var _gap9: Float = 0, _gap10: Float = 0, _gap11: Float = 0
    var eye: SIMD3<Float>
    var featherStrength: Float
    var bandRadians: Float
    var glowRadians: Float
    var whitenRadians: Float
    var featherRadians: Float
    var groundBandRadians: Float
    var groundGain: Float
    var cutoffStartRadians: Float
    var cutoffEndRadians: Float
    var _gap12: Float = 0, _gap13: Float = 0, _gap14: Float = 0
    var skyColor: SIMD3<Float>
    var skyOpacity: Float
    var skyGradientRadians: Float
    var _gap15: Float = 0, _gap16: Float = 0
    /// The frame's view-projection: the band's vertices are directions the
    /// shader places in the world and projects.
    var viewProjection: matrix_float4x4
    /// The band's top station, radians above the edge.
    var bandTopRadians: Float
    var _gap17: Float = 0, _gap18: Float = 0, _gap19: Float = 0

    static func make(haze: HorizonHaze,
                     projectionView: matrix_float4x4,
                     cameraEye: SIMD3<Float>) -> HorizonUniform {
        HorizonUniform(up: haze.edge.up,
                       depression: haze.edge.depression,
                       center: haze.center,
                       sunInfluence: haze.sunInfluence,
                       light: haze.light,
                       skyStrength: haze.skyStrength,
                       tint: haze.tint,
                       whitenWeight: haze.whitenWeight,
                       eye: cameraEye,
                       featherStrength: haze.featherStrength,
                       bandRadians: haze.bandRadians,
                       glowRadians: haze.glowRadians,
                       whitenRadians: haze.whitenRadians,
                       featherRadians: haze.featherRadians,
                       groundBandRadians: haze.groundBandRadians,
                       groundGain: haze.groundGain,
                       cutoffStartRadians: haze.cutoffStartRadians,
                       cutoffEndRadians: haze.cutoffEndRadians,
                       skyColor: haze.skyColor,
                       skyOpacity: haze.skyOpacity,
                       skyGradientRadians: haze.skyGradientRadians,
                       viewProjection: projectionView,
                       bandTopRadians: haze.bandTopRadians)
    }
}
