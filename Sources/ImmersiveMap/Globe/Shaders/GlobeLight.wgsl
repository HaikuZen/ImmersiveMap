// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: GlobeLight.h fnv1a64=ea0e9ee1ef9e0edd

// The sun on the globe (GlobeLightSettings): the surface shaded by the
// sphere's normal against the scene light, the night side drawn toward the
// night colour, a soft terminator between. Every fragment stage of the
// globe's surface multiplies its colour through globeLitColor, from the
// fragment binding of Metal's kGlobeLightBufferIndex (9).

/// Mirror of GlobeLightUniform.swift.
struct GlobeLight {
    /// The direction toward the sun in world space, unit length, and how
    /// much of the shading the surface takes this frame (0 none).
    lightAndStrength: vec4f,
    /// The colour the night side is drawn toward and the terminator's
    /// softness in the cosine of the sun's angle to the normal.
    nightColorAndSoftness: vec4f,
}

/// A surface colour under the globe's light at a point whose sphere normal
/// (world space) is `normal`: the colour itself where the normal faces the
/// sun, toward the night colour where it faces away, a smoothstep across
/// the terminator, all of it scaled by the strength. Metal's runs in half,
/// here in f32: WGSL's f16 is an optional feature.
fn globeLitColor(color: vec3f, normal: vec3f, light: GlobeLight) -> vec3f {
    let strength = light.lightAndStrength.w;
    if (strength <= 0.0) {
        return color;
    }
    let softness = max(light.nightColorAndSoftness.w, 1e-3);
    let day = smoothstep(-softness, softness, dot(normalize(normal), light.lightAndStrength.xyz));
    return mix(color, light.nightColorAndSoftness.rgb, strength * (1.0 - day));
}
