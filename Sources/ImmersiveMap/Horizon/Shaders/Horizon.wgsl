// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: Horizon.metal fnv1a64=4031514c680818d8

// The horizon layer: the air around the surface's visible edge, resolved per
// pixel from the view ray, drawn twice by the depth buffer (the sky side
// over what nothing painted, the ground side over what was painted, its
// angle clamped to the edge). The band of directions around the eye's local
// vertical feeds both. Pure arithmetic, no texture reads, no discard.
// Horizon.metal explains the profile and the band.

/// Mirrors HorizonUniform.swift.
struct Horizon {
    @size(16) up: vec3f,
    depression: f32,
    @size(16) center: vec3f,
    sunInfluence: f32,
    @size(16) light: vec3f,
    skyStrength: f32,
    @size(16) tint: vec3f,
    whitenWeight: f32,
    @size(16) eye: vec3f,
    featherStrength: f32,
    bandRadians: f32,
    glowRadians: f32,
    whitenRadians: f32,
    featherRadians: f32,
    groundBandRadians: f32,
    groundGain: f32,
    cutoffStartRadians: f32,
    cutoffEndRadians: f32,
    @size(16) skyColor: vec3f,
    skyOpacity: f32,
    skyGradientRadians: f32,
    viewProjection: mat4x4f,
    bandTopRadians: f32,
}

/// True for the ground-side draw: the angle is clamped to the edge.
@id(0) override kHorizonGroundSide: bool;

// The sky side's profile, weights of the band hugging the edge and of the
// wide glow away from it.
const kHorizonBandWeight = 0.85;
const kHorizonGlowWeight = 0.22;
const kHorizonBandStations = 8;
const kHalfPi = 1.5707963267948966;

@group(0) @binding(1) var<uniform> horizon: Horizon;
@group(1) @binding(0) var<uniform> fragmentHorizon: Horizon;

/// Signed angle of a unit view direction above the edge: its elevation over
/// the eye's local horizontal plus the limb's depression. Mirrored by
/// HorizonEdgeMath.angleAboveEdge.
fn horizonAngleAboveEdge(h: Horizon, direction: vec3f) -> f32 {
    return asin(clamp(dot(direction, h.up), -1.0, 1.0)) + h.depression;
}

/// The atmosphere outside the edge: a bright band hugging the limb and a
/// wide faint glow into space.
fn horizonSkyProfile(h: Horizon, aboveRadians: f32) -> f32 {
    let band = exp(-aboveRadians / h.bandRadians);
    let glow = exp(-aboveRadians / h.glowRadians);
    return saturate(band * kHorizonBandWeight + glow * kHorizonGlowWeight);
}

/// The haze over the surface below the edge, cut off smoothly so the map
/// under the camera stays clean. Mirrored by
/// HorizonFrameResolver.groundProfile.
fn horizonGroundProfile(h: Horizon, belowRadians: f32) -> f32 {
    let amount = saturate(exp(-belowRadians / h.groundBandRadians) * h.groundGain);
    let cutoff = 1.0 - smoothstep(h.cutoffStartRadians, h.cutoffEndRadians, belowRadians);
    return amount * cutoff;
}

/// The sun's side of the limb: the halo is full where the limb normal faces
/// the scene light and dims opposite it, by the frame's sun influence.
fn horizonSunFactor(h: Horizon, direction: vec3f) -> f32 {
    if (h.sunInfluence <= 0.0) {
        return 1.0;
    }
    let toCenter = h.center - h.eye;
    let nearest = h.eye + direction * max(dot(toCenter, direction), 0.0);
    let normal = normalize(nearest - h.center);
    let day = smoothstep(-0.25, 0.25, dot(normal, h.light));
    return 1.0 - h.sunInfluence * (1.0 - day);
}

/// The haze of one direction, `above` radians above the edge, premultiplied
/// over what is behind, the coverage in alpha.
fn horizonShade(h: Horizon, above: f32, direction: vec3f) -> vec4f {
    var haze: f32;
    if (above >= 0.0) {
        haze = horizonSkyProfile(h, above) * h.skyStrength * horizonSunFactor(h, direction);
    } else {
        haze = horizonGroundProfile(h, -above);
    }
    let distanceToEdge = abs(above);
    let feather = exp(-distanceToEdge / h.featherRadians) * h.featherStrength;
    let whiten = exp(-distanceToEdge / h.whitenRadians) * h.whitenWeight;

    var coverage = saturate(haze + feather * (1.0 - haze));
    var color = mix(h.tint, vec3f(1.0), whiten) * coverage;
    if (!kHorizonGroundSide && above >= 0.0 && h.skyOpacity > 0.0) {
        // The plane's sky under the halo: a glow of the tint at the line
        // decaying into the sky colour, faded in through the morph.
        let gradient = 1.0 - exp(-above / h.skyGradientRadians);
        let sky = mix(h.tint, h.skyColor, gradient) * h.skyOpacity;
        color += sky * (1.0 - coverage);
        coverage += h.skyOpacity * (1.0 - coverage);
    }
    return vec4f(color, coverage);
}

/// A vertex of the band: a station (one of the angles either side of the
/// edge, HorizonBandMath.swift) and an azimuth about the eye's vertical.
struct HorizonBandVertexIn {
    @location(0) azimuth: f32,
    @location(1) station: f32,
}

struct HorizonBandVertexOut {
    @builtin(position) position: vec4f,
    @location(0) direction: vec3f,
}

/// The band's angles above the edge, station by station, kept in order by a
/// running maximum and on the sphere of directions.
fn horizonBandStationAngle(h: Horizon, station: i32) -> f32 {
    let feather = h.featherRadians * 4.0;
    var angles = array<f32, kHorizonBandStations>(
        -h.cutoffEndRadians,
        -h.cutoffStartRadians,
        -max(h.groundBandRadians, feather),
        0.0,
        max(h.bandRadians, feather),
        h.bandRadians * 3.0,
        h.glowRadians,
        h.bandTopRadians
    );
    var angle = angles[0];
    for (var index = 1; index <= station; index += 1) {
        angle = max(angle, angles[index]);
    }
    let limit = kHalfPi - 1e-3;
    return clamp(angle, h.depression - limit, h.depression + limit);
}

@vertex
fn horizonBandVertexShader(vertexIn: HorizonBandVertexIn) -> HorizonBandVertexOut {
    let above = horizonBandStationAngle(horizon, i32(vertexIn.station));
    // A basis across the local vertical: the band wraps all the way round.
    var reference = vec3f(1.0, 0.0, 0.0);
    if (abs(horizon.up.z) < 0.9) {
        reference = vec3f(0.0, 0.0, 1.0);
    }
    let east = normalize(cross(reference, horizon.up));
    let north = cross(horizon.up, east);
    let elevation = above - horizon.depression;
    let direction = cos(elevation) * (cos(vertexIn.azimuth) * east + sin(vertexIn.azimuth) * north)
        + sin(elevation) * horizon.up;
    var out: HorizonBandVertexOut;
    out.position = horizon.viewProjection * vec4f(horizon.eye + direction, 1.0);
    // At the far plane.
    out.position.z = out.position.w;
    out.direction = direction;
    return out;
}

@fragment
fn horizonBandFragmentShader(in: HorizonBandVertexOut) -> @location(0) vec4f {
    let direction = normalize(in.direction);
    var above = horizonAngleAboveEdge(fragmentHorizon, direction);
    if (kHorizonGroundSide) {
        above = min(above, 0.0);
    }
    return horizonShade(fragmentHorizon, above, direction);
}
