// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: StarfieldStars.metal fnv1a64=f7394c001441bd58
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl

// The stars around the globe, blended additively over space. Metal draws
// each as a sized point sprite, which WebGPU does not have: here each star
// is a quad of six vertices, instanced, the star read from a storage buffer
// by the instance index, its size in pixels turned into clip space by the
// drawable's size, and the sprite coordinate (Metal's point_coord, 0 at
// the top left corner) made from the corner. StarfieldStars.metal explains
// the shading.

/// Mirrors StarfieldStarVertex: 48 bytes, the position's vec3f taking 16.
struct StarVertex {
    @size(16) position: vec3f,
    size: f32,
    brightness: f32,
    temperature: f32,
    twinklePhase: f32,
    halo: f32,
}

/// Mirrors StarfieldParamsUniform.
struct StarfieldParams {
    /// The globe's pan rotation, row-vector layout (`v * M`).
    rotation: mat4x4f,
    radiusScale: f32,
    @size(16) padding: vec3f,
}

/// Mirrors StarfieldQuadUniform: the drawable's size in pixels.
struct StarfieldQuad {
    viewportSizePx: vec2f,
}

struct StarVertexOut {
    @builtin(position) position: vec4f,
    @location(0) brightness: f32,
    @location(1) temperature: f32,
    @location(2) twinklePhase: f32,
    @location(3) halo: f32,
    /// Metal's point_coord: 0...1 across the sprite, y down.
    @location(4) pointCoord: vec2f,
}

@group(0) @binding(0) var<storage, read> stars: array<StarVertex>;
@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(2) var<uniform> globe: Globe;
@group(0) @binding(3) var<uniform> params: StarfieldParams;
@group(0) @binding(4) var<uniform> quad: StarfieldQuad;

@group(1) @binding(0) var<uniform> time: f32;

/// Metal's translationMatrix (GeoMath.metal): a translation in the
/// row-vector layout the starfield multiplies with.
fn starTranslationMatrix(t: vec3f) -> mat4x4f {
    return mat4x4f(vec4f(1.0, 0.0, 0.0, t.x),
                   vec4f(0.0, 1.0, 0.0, t.y),
                   vec4f(0.0, 0.0, 1.0, t.z),
                   vec4f(0.0, 0.0, 0.0, 1.0));
}

@vertex
fn starfieldQuadVertexShader(@builtin(vertex_index) vertexID: u32,
                             @builtin(instance_index) instanceID: u32) -> StarVertexOut {
    var corners = array<vec2f, 6>(vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0),
                                  vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
    let star = stars[instanceID];
    let starRadius = globe.radius * params.radiusScale;
    let world = vec4f(star.position * starRadius, 1.0) * params.rotation * starTranslationMatrix(vec3f(0.0, 0.0, -globe.radius));
    var position = camera.matrix * world;
    // Stars are background: at the far plane, so the sky depth test rejects
    // them wherever the globe surface has written depth.
    position.z = position.w;
    let sizeScale = starRadius / globe.radius;
    let pointSize = max(1.2, star.size * sizeScale * 0.32);
    // The sprite's corner, half its size in pixels from the centre, in
    // clip space.
    let corner = corners[vertexID % 6u];
    position = vec4f(position.xy + corner * (pointSize * 0.5) / (quad.viewportSizePx * 0.5) * position.w, position.zw);

    var out: StarVertexOut;
    out.position = position;
    out.brightness = star.brightness;
    out.temperature = star.temperature;
    out.twinklePhase = star.twinklePhase;
    out.halo = star.halo;
    out.pointCoord = vec2f(corner.x * 0.5 + 0.5, 0.5 - corner.y * 0.5);
    return out;
}

@fragment
fn starfieldQuadFragmentShader(in: StarVertexOut) -> @location(0) vec4f {
    let centered = in.pointCoord * 2.0 - 1.0;
    let radiusSquared = dot(centered, centered);
    if (radiusSquared > 1.0) {
        discard;
    }

    let core = exp(-radiusSquared * 7.8);
    let halo = exp(-radiusSquared * 2.35) * (0.45 + in.halo * 0.95);
    let crossGlow = exp(-abs(centered.x * centered.y) * 10.0) * 0.08 * in.halo;
    let twinkle = 0.9 + 0.1 * sin(time * (1.0 + in.halo * 1.3) + in.twinklePhase);
    let intensity = in.brightness * twinkle;

    let warm = vec3f(1.0, 0.88, 0.78);
    let neutral = vec3f(0.96, 0.97, 1.0);
    let cool = vec3f(0.72, 0.83, 1.0);
    let clampedTemperature = clamp(in.temperature, 0.0, 1.0);
    var color: vec3f;
    if (clampedTemperature < 0.5) {
        color = mix(warm, neutral, clampedTemperature * 2.0);
    } else {
        color = mix(neutral, cool, (clampedTemperature - 0.5) * 2.0);
    }

    let alpha = saturate(core * 0.95 + halo * 0.55 + crossGlow) * intensity;
    let emissive = color * (core * 1.3 + halo * 0.75 + crossGlow * 1.6) * intensity;
    return vec4f(emissive, alpha);
}
