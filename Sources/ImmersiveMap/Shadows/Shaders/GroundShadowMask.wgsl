// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: GroundShadowMask.metal fnv1a64=fd9eb3665ec2dae5
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl

// The ground shadow mask: the shadow factor of the flat ground plane
// (z = 0), one value per screen pixel, computed once per frame by a
// fullscreen pass, so the stacked ground layers read it with one texture
// read instead of sampling the shadow map each. GroundShadowMask.metal
// explains the pass.

/// Mirrors GroundShadowMaskUniform.swift.
struct GroundShadowMaskUniform {
    /// Inverse of the camera's projection-view: maps NDC (x, y in -1...1,
    /// z in 0...1) back to world space.
    inverseProjectionView: mat4x4f,
    /// Mask size in pixels.
    viewportSize: vec2f,
    _padding: vec2f,
}

@group(1) @binding(0) var<uniform> mask: GroundShadowMaskUniform;
@group(1) @binding(1) var<uniform> shadow: Shadow;
@group(1) @binding(16) var shadowMap: texture_depth_2d_array;
@group(1) @binding(48) var shadowCompareSampler: sampler_comparison;

struct GroundShadowMaskVertexOut {
    @builtin(position) position: vec4f,
}

/// One fullscreen triangle in clip space. The fragment reconstructs the
/// world ray from its own pixel position, so nothing is interpolated.
@vertex
fn groundShadowMaskVertexShader(@builtin(vertex_index) vertexID: u32) -> GroundShadowMaskVertexOut {
    var positions = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    var out: GroundShadowMaskVertexOut;
    out.position = vec4f(positions[vertexID], 0.0, 1.0);
    return out;
}

/// Intersects the pixel's view ray with the ground plane and samples the
/// shadow windows there. The plane always faces up, so the factor reduces
/// to 1 - (1 - mapVisibility) * strength * fade. Nothing here takes a
/// derivative, so pixels above the horizon and beyond the fade return lit
/// without touching the map.
@fragment
fn groundShadowMaskFragmentShader(in: GroundShadowMaskVertexOut) -> @location(0) f32 {
    let ndc = vec2f(2.0 * in.position.x / mask.viewportSize.x - 1.0,
                    1.0 - 2.0 * in.position.y / mask.viewportSize.y);
    let nearPoint = mask.inverseProjectionView * vec4f(ndc, 0.0, 1.0);
    let farPoint = mask.inverseProjectionView * vec4f(ndc, 1.0, 1.0);
    let rayStart = nearPoint.xyz / nearPoint.w;
    let rayEnd = farPoint.xyz / farPoint.w;
    let rayDirection = rayEnd - rayStart;
    // Where along the ray the plane lies. Negative or past the far plane
    // means the ray never reaches the ground within the view volume.
    let denominator = rayDirection.z;
    if (abs(denominator) <= 1e-12) {
        return 1.0;
    }
    let t = -rayStart.z / denominator;
    if (t < 0.0 || t > 1.0) {
        return 1.0;
    }
    var worldPosition = rayStart + rayDirection * t;
    worldPosition.z = 0.0;

    if (shadow.strength <= 0.0) {
        return 1.0;
    }
    let blend = shadowCascadeBlend(shadow, worldPosition.xy);
    if (blend.fade <= 0.0) {
        return 1.0;
    }

    let mapVisibility = shadowMapVisibility(shadow, shadowMap, shadowCompareSampler, worldPosition, vec3f(0.0), blend);
    return 1.0 - (1.0 - mapVisibility) * shadow.strength * blend.fade;
}
