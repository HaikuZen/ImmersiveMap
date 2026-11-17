// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: FXAA.metal fnv1a64=e6f003c73f8bae36

// The FXAA pass (FXAAPipeline): one triangle over the frame, smoothing the
// edges of the frame drawn before it. FXAA.metal explains the early out,
// the alpha and the blend. Metal runs the luma and colour math in half;
// WGSL's f16 is an optional feature, so it runs in f32 here, finer than the
// 8-bit source needs.

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
}

/// Mirror of FXAAPipeline.Uniform.
struct FXAAUniform {
    inverseViewportSize: vec2f,
}

@group(1) @binding(0) var<uniform> fxaa: FXAAUniform;
@group(1) @binding(16) var sourceTexture: texture_2d<f32>;
/// Metal's inline sampler: linear, clamped to the edge.
@group(1) @binding(49) var sourceSampler: sampler;

@vertex
fn postProcessingVertexShader(@builtin(vertex_index) vertexID: u32) -> VertexOut {
    var positions = array<vec2f, 3>(
        vec2f(-1.0, -1.0),
        vec2f(3.0, -1.0),
        vec2f(-1.0, 3.0),
    );

    var out: VertexOut;
    let clip = positions[vertexID];
    out.position = vec4f(clip, 0.0, 1.0);
    out.uv = vec2f(clip.x * 0.5 + 0.5, 0.5 - clip.y * 0.5);
    return out;
}

@fragment
fn fxaaFragmentShader(in: VertexOut) -> @location(0) vec4f {
    // Every sample is taken before the early out: WGSL samples with
    // derivatives only in uniform control flow.
    let texel = fxaa.inverseViewportSize;
    let centerSample = textureSample(sourceTexture, sourceSampler, in.uv);
    let center = centerSample.rgb;
    let nw = textureSample(sourceTexture, sourceSampler, in.uv + texel * vec2f(-1.0, -1.0)).rgb;
    let ne = textureSample(sourceTexture, sourceSampler, in.uv + texel * vec2f(1.0, -1.0)).rgb;
    let sw = textureSample(sourceTexture, sourceSampler, in.uv + texel * vec2f(-1.0, 1.0)).rgb;
    let se = textureSample(sourceTexture, sourceSampler, in.uv + texel * vec2f(1.0, 1.0)).rgb;

    let lumaWeights = vec3f(0.299, 0.587, 0.114);
    let lumaNW = dot(nw, lumaWeights);
    let lumaNE = dot(ne, lumaWeights);
    let lumaSW = dot(sw, lumaWeights);
    let lumaSE = dot(se, lumaWeights);
    let lumaM = dot(center, lumaWeights);

    let lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    let lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

    var direction: vec2f;
    direction.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE));
    direction.y = ((lumaNW + lumaSW) - (lumaNE + lumaSE));

    let directionReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * 0.03125, 0.0078125);
    let inverseDirectionAdjustment = 1.0 / (min(abs(direction.x), abs(direction.y)) + directionReduce);
    let sampleStep = clamp(direction * inverseDirectionAdjustment, vec2f(-8.0), vec2f(8.0)) * texel;

    let resultA = 0.5 * (
        textureSample(sourceTexture, sourceSampler, in.uv + sampleStep * (1.0 / 3.0 - 0.5)) +
        textureSample(sourceTexture, sourceSampler, in.uv + sampleStep * (2.0 / 3.0 - 0.5))
    );
    let resultB = resultA * 0.5 + 0.25 * (
        textureSample(sourceTexture, sourceSampler, in.uv + sampleStep * -0.5) +
        textureSample(sourceTexture, sourceSampler, in.uv + sampleStep * 0.5)
    );

    // Low-contrast early out, as FXAA.metal's.
    if (lumaMax - lumaMin < max(0.0312, lumaMax * 0.125)) {
        return centerSample;
    }
    let lumaB = dot(resultB.rgb, lumaWeights);
    return select(resultB, resultA, lumaB < lumaMin || lumaB > lumaMax);
}
