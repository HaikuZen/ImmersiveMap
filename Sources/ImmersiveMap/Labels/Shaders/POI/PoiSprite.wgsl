// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: PoiSprite.metal fnv1a64=c0e96d6250af3a0e
// include: ../Shared/LabelTextCommon.wgsl

// The POI icons: an icon from the sprite atlas over a round plate, placed
// like a label. The quad is also the route shields' (RouteShield.wgsl).

/// Mirrors PoiIconStyleUniform.
struct PoiIconStyle {
    backgroundColor: vec4f,
    iconColor: vec4f,
    /// The plate's and the icon's opacity together, applied to the
    /// composite.
    opacity: f32,
}

@group(0) @binding(1) var<uniform> matrix: mat4x4f;
@group(0) @binding(2) var<storage, read> screenPositions: array<ScreenPointOutput>;
@group(0) @binding(3) var<uniform> globalTextShift: i32;
@group(0) @binding(6) var<storage, read> labelMeta: array<LabelRuntimeMeta>;
@group(0) @binding(7) var<uniform> pixelsPerPoint: f32;

@group(1) @binding(0) var<uniform> style: PoiIconStyle;
@group(1) @binding(16) var atlasTexture: texture_2d<f32>;
@group(1) @binding(49) var linearSampler: sampler;

@vertex
fn poiSpriteVertex(vertexIn: LabelVertexIn) -> VertexOut {
    let screenIndex = vertexIn.labelIndex + globalTextShift;
    return labelQuadVertex(vertexIn, matrix, screenPositions[screenIndex], labelMeta[screenIndex], pixelsPerPoint);
}

@fragment
fn poiSpriteFragment(in: VertexOut) -> @location(0) vec4f {
    let texel = textureSample(atlasTexture, linearSampler, in.uv);
    let centeredUV = in.spriteUV * 2.0 - 1.0;
    let circleDistance = length(centeredUV);
    let circleAlpha = 1.0 - smoothstep(0.82, 0.96, circleDistance);
    let iconAlpha = texel.a;

    let backgroundAlpha = circleAlpha * in.alpha * style.backgroundColor.a;
    let foregroundAlpha = iconAlpha * in.alpha * style.iconColor.a;
    let alpha = foregroundAlpha + backgroundAlpha * (1.0 - foregroundAlpha);
    let color = style.iconColor.rgb * foregroundAlpha
        + style.backgroundColor.rgb * backgroundAlpha * (1.0 - foregroundAlpha);
    // The pipeline blends by the source alpha, so the opacity scales the
    // alpha alone: the composite fades as one.
    return vec4f(color, alpha * style.opacity);
}
