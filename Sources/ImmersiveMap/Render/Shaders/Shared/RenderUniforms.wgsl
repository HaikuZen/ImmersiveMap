// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: RenderUniforms.h fnv1a64=2cc0d28bd7943bda

// The uniforms the WGSL stages share: the twins of RenderUniforms.h and of
// their Swift mirrors, with the same fields at the same offsets
// (WGSLLayoutTests). Metal's float3 and Swift's SIMD3 take 16 bytes, so a
// vec3f here takes @size(16), or the field after it moves. Only what a
// ported shader reads is here so far.

/// Mirror of CameraUniform.swift.
struct Camera {
    matrix: mat4x4f,
    @size(16) eye: vec3f,
    _padding: f32,
}

/// Mirror of GlobeUniform.swift.
struct Globe {
    panX: f32,
    panY: f32,
    radius: f32,
    transition: f32,
}

/// Per-frame derivatives of Globe, computed once on the CPU instead of once
/// per vertex. Mirrors GlobeFrameConstantsUniform.swift.
struct GlobeFrameConstants {
    /// The pan rotation, in the row-vector layout the vertex stages
    /// multiply with (`v * M`).
    rotation: mat4x4f,
    /// Unit earth direction straight to clip space: camera x translate x
    /// pan rotation x radius. Column-vector layout (`M * v`).
    sphereClip: mat4x4f,
    /// Unit earth direction to the world-space sphere position: translate x
    /// pan rotation x radius. Column-vector layout.
    sphereWorld: mat4x4f,
    mapSize: f32,
    panMercatorY: f32,
    panLatitude: f32,
    panLongitude: f32,
    /// The unroll curvature (1 - transition) / radius: 0 is the plane.
    curvature: f32,
    @size(16) _padding: vec3f,
}

// MARK: - Inline samplers

// Metal declares some samplers inside a shader (`constexpr sampler`), and
// WGSL has none: such a sampler is a binding of its stage's group at 48 + k,
// which the WebGPU backend binds itself from this table, so the Swift side
// binds nothing for it.
//
// 48: the shadow comparison sampler. Linear, no mip filter, clamped to the
//     edge, compared with less-equal.

// MARK: - Shadows

// The slices of the shadow map, one per window. Mirrored by
// ShadowCascadeSlot.swift.
const kShadowNearSlice: u32 = 0u;
const kShadowFarSlice: u32 = 1u;

/// One shadow window. Mirrors ShadowCascadeUniform.swift.
/// worldToShadowTexture maps world space straight to the window's slice:
/// xy the texture UV, z the comparison depth.
struct ShadowCascade {
    worldToShadowTexture: mat4x4f,
    /// The factor the tent's taps are pushed out by, about the sample
    /// point. 1 is the plain 3x3 tent.
    tentSpread: f32,
    /// Where the window's shadows start to fade and where they are gone,
    /// as radial distances from Shadow.fadeCenter.
    fadeStartDistance: f32,
    depthBias: f32,
    fadeEndDistance: f32,
    /// Valid UV rectangle, inset so the tent's taps never leave the window.
    uvMinimum: vec2f,
    uvMaximum: vec2f,
    /// World-space normal-offset distance for receivers with normals.
    normalOffsetWorld: f32,
    _padding0: f32,
    /// One texel in UV.
    texelSizeUV: vec2f,
}

/// Light matrix of a caster pass. Mirrors ShadowCasterUniform.swift.
struct ShadowCasterMatrices {
    lightProjectionView: mat4x4f,
}

/// Directional shadow sampling parameters. Mirrors ShadowUniform.swift.
struct Shadow {
    /// The near window, sharp, and the far window, coarse. A far window the
    /// frame has not got has an empty UV rectangle.
    near: ShadowCascade,
    far: ShadowCascade,
    @size(16) eye: vec3f,
    strength: f32,
    _padding0: f32,
    _padding1: f32,
    _padding2: f32,
    /// Normalized direction towards the sun.
    @size(16) lightDirection: vec3f,
    /// RGB cast of a fully shadowed surface on top of the darkening.
    @size(16) tint: vec3f,
    /// Centre of the windows in world XY: what every fade distance is
    /// measured from.
    fadeCenter: vec2f,
    _padding3: vec2f,
}

fn shadowCascadeIsEnabled(cascade: ShadowCascade) -> bool {
    return cascade.uvMaximum.x >= cascade.uvMinimum.x;
}

/// Which window a point reads and how far its shadows have faded there.
struct ShadowCascadeBlend {
    /// 1 inside the near window, 0 past its fade band.
    nearWeight: f32,
    /// 1 at full shadow strength, 0 where the shadows have ended.
    fade: f32,
    hasFar: bool,
}

fn shadowCascadeBlend(shadow: Shadow, worldXY: vec2f) -> ShadowCascadeBlend {
    let distanceToCenter = length(worldXY - shadow.fadeCenter);
    var blend: ShadowCascadeBlend;
    blend.hasFar = shadowCascadeIsEnabled(shadow.far);
    blend.nearWeight = 1.0 - smoothstep(shadow.near.fadeStartDistance, shadow.near.fadeEndDistance, distanceToCenter);
    if (blend.hasFar) {
        blend.fade = 1.0 - smoothstep(shadow.far.fadeStartDistance, shadow.far.fadeEndDistance, distanceToCenter);
    } else {
        blend.fade = blend.nearWeight;
    }
    return blend;
}

fn shadowWindowContains(cascade: ShadowCascade, uvz: vec3f) -> bool {
    return uvz.x >= cascade.uvMinimum.x && uvz.x <= cascade.uvMaximum.x &&
           uvz.y >= cascade.uvMinimum.y && uvz.y <= cascade.uvMaximum.y &&
           uvz.z >= 0.0 && uvz.z <= 1.0;
}

/// Castano's 3x3 tent PCF: four bilinear compares with computed weights
/// reconstruct a tent kernel, the same ramp in every orientation, widened
/// about the sample point by `tentSpread`. RenderUniforms.h explains the
/// kernel. Level 0 is sampled, as Metal's sampler has no mip filter, which
/// also lets the caller branch around the call.
fn shadowWindowVisibility(cascade: ShadowCascade,
                          shadowMap: texture_depth_2d_array,
                          shadowSampler: sampler_comparison,
                          slice: u32,
                          uvz: vec3f) -> f32 {
    let reference = uvz.z - cascade.depthBias;

    let texelCoords = uvz.xy / cascade.texelSizeUV;
    let base = floor(texelCoords + 0.5);
    let s = texelCoords.x + 0.5 - base.x;
    let t = texelCoords.y + 0.5 - base.y;
    let baseUV = (base - 0.5) * cascade.texelSizeUV;

    let uw0 = 3.0 - 2.0 * s;
    let uw1 = 1.0 + 2.0 * s;
    let vw0 = 3.0 - 2.0 * t;
    let vw1 = 1.0 + 2.0 * t;
    // The tap offsets, scaled about the sample point by the spread: the
    // ramp gets longer, its centre stays.
    let spread = cascade.tentSpread;
    let u0 = s + ((2.0 - s) / uw0 - 1.0 - s) * spread;
    let u1 = s + (s / uw1 + 1.0 - s) * spread;
    let v0 = t + ((2.0 - t) / vw0 - 1.0 - t) * spread;
    let v1 = t + (t / vw1 + 1.0 - t) * spread;

    var visibility = 0.0;
    visibility += uw0 * vw0 * textureSampleCompareLevel(shadowMap, shadowSampler,
                                                        baseUV + vec2f(u0, v0) * cascade.texelSizeUV, slice, reference);
    visibility += uw1 * vw0 * textureSampleCompareLevel(shadowMap, shadowSampler,
                                                        baseUV + vec2f(u1, v0) * cascade.texelSizeUV, slice, reference);
    visibility += uw0 * vw1 * textureSampleCompareLevel(shadowMap, shadowSampler,
                                                        baseUV + vec2f(u0, v1) * cascade.texelSizeUV, slice, reference);
    visibility += uw1 * vw1 * textureSampleCompareLevel(shadowMap, shadowSampler,
                                                        baseUV + vec2f(u1, v1) * cascade.texelSizeUV, slice, reference);
    return visibility * (1.0 / 16.0);
}

/// One window's visibility at a point: the receiver stepped off its surface
/// by the window's normal offset (`normal` zero for the ground), projected
/// into the window's slice, lit outside its sampling rectangle.
fn shadowCascadeVisibility(cascade: ShadowCascade,
                           shadowMap: texture_depth_2d_array,
                           shadowSampler: sampler_comparison,
                           slice: u32,
                           worldPos: vec3f,
                           normal: vec3f) -> f32 {
    let position = worldPos + normal * cascade.normalOffsetWorld;
    // The light projection is orthographic, so w is 1.
    let uvz = (cascade.worldToShadowTexture * vec4f(position, 1.0)).xyz;
    if (shadowWindowContains(cascade, uvz)) {
        return shadowWindowVisibility(cascade, shadowMap, shadowSampler, slice, uvz);
    }
    return 1.0;
}

/// The map's visibility at a point, 1 fully lit: the near window where it
/// reaches, the far window beyond it, the two blended over the near
/// window's fade band.
fn shadowMapVisibility(shadow: Shadow,
                       shadowMap: texture_depth_2d_array,
                       shadowSampler: sampler_comparison,
                       worldPos: vec3f,
                       normal: vec3f,
                       blend: ShadowCascadeBlend) -> f32 {
    var nearVisibility = 1.0;
    if (blend.nearWeight > 0.0) {
        nearVisibility = shadowCascadeVisibility(shadow.near, shadowMap, shadowSampler, kShadowNearSlice, worldPos, normal);
    }
    if (!blend.hasFar) {
        return nearVisibility;
    }
    var farVisibility = 1.0;
    if (blend.nearWeight < 1.0) {
        farVisibility = shadowCascadeVisibility(shadow.far, shadowMap, shadowSampler, kShadowFarSlice, worldPos, normal);
    }
    return mix(farVisibility, nearVisibility, blend.nearWeight);
}
