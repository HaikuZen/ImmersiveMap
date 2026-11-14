// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: GroundFog.h fnv1a64=d572f4bf7ffcd84a

// The fog on the ground of the flat map (GroundFogSettings): thickest at
// the ground, its density falling by a factor of e every `height` upward,
// gathered along the view ray past `startDistance`. Every shader of what
// stands on the map mixes its colour toward the fog's by groundFogAmount,
// from the fragment binding of Metal's kGroundFogBufferIndex (12).
// GroundFog.h explains the integrals.

/// Mirror of GroundFogUniform.swift.
struct GroundFog {
    /// The fog's colour at the horizon line and its density at the ground,
    /// per meter.
    colorAndDensity: vec4f,
    /// The eye in render world units and the meters one unit spans.
    eyeAndMetersPerUnit: vec4f,
    /// The height its density falls by e over and the distance it begins
    /// at, in meters, the most it veils, and its strength.
    parameters: vec4f,
    /// The sky's colour away from the line and the e-fold of the horizon's
    /// glow, in radians above the line (0: the fog keeps its colour).
    skyColorAndGradient: vec4f,
    /// The distance the density takes to come in past its start, the
    /// altitude of the plane the ground is drawn from, and the altitude the
    /// density is stated at, in meters. The rest is padding.
    startSoftness: vec4f,
}

/// How much of the fog lies between the eye and a point, 0 to 1.
fn groundFogAmount(worldPosition: vec3f, fog: GroundFog) -> f32 {
    let strength = fog.parameters.w;
    if (strength <= 0.0) {
        return 0.0;
    }
    let metersPerUnit = fog.eyeAndMetersPerUnit.w;
    let eye = fog.eyeAndMetersPerUnit.xyz * metersPerUnit;
    let ray = worldPosition * metersPerUnit - eye;
    let rayLength = length(ray);
    let start = fog.parameters.y;
    if (rayLength <= start) {
        return 0.0;
    }
    let height = max(fog.parameters.x, 1e-3);
    // Heights over the altitude the density is stated at.
    let base = fog.startSoftness.y - fog.startSoftness.z;
    let z0 = max(eye.z + ray.z * (start / rayLength) + base, 0.0);
    let z1 = max(eye.z + ray.z + base, 0.0);
    let rise = (z1 - z0) / height;
    let e0 = exp(-z0 / height);
    var meanDensity = e0;
    if (abs(rise) > 1e-4) {
        meanDensity = (e0 - exp(-z1 / height)) / rise;
    }
    let span = rayLength - start;
    let softness = fog.startSoftness.x;
    var weightedSpan = span;
    if (softness > 0.0) {
        let t = span / softness;
        if (t < 1.0) {
            weightedSpan = softness * (t * t * t - 0.5 * t * t * t * t);
        } else {
            weightedSpan = span - 0.5 * softness;
        }
    }
    let opticalDepth = fog.colorAndDensity.w * weightedSpan * meanDensity;
    return min(1.0 - exp(-opticalDepth), fog.parameters.z) * strength;
}

/// The fog's colour in the direction of a point: its own colour at and under
/// the horizon line, decaying into the sky colour above it. Mirrored by
/// GroundFogUniform.color(elevation:).
fn groundFogColor(worldPosition: vec3f, fog: GroundFog) -> vec3f {
    let base = fog.colorAndDensity.rgb;
    let gradient = fog.skyColorAndGradient.w;
    if (gradient <= 0.0) {
        return base;
    }
    let ray = worldPosition - fog.eyeAndMetersPerUnit.xyz;
    let rayLength = length(ray);
    if (rayLength <= 0.0) {
        return base;
    }
    let elevation = asin(clamp(ray.z / rayLength, -1.0, 1.0));
    if (elevation <= 0.0) {
        return base;
    }
    return mix(base, fog.skyColorAndGradient.rgb, 1.0 - exp(-elevation / gradient));
}

fn applyGroundFog(color: vec3f, worldPosition: vec3f, fog: GroundFog) -> vec3f {
    let amount = groundFogAmount(worldPosition, fog);
    if (amount <= 0.0) {
        return color;
    }
    return mix(color, groundFogColor(worldPosition, fog), amount);
}
