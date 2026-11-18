// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: RoadLabelTextVertex.metal fnv1a64=3c17ad57c5f6441a
// ported-from: RoadLabelCommon.h fnv1a64=bc0c74845a9255a8
// include: ../Shared/LabelTextCommon.wgsl

// The road names' vertex stage: each glyph turned along its road at the
// place the CPU laid it out this frame, with the depth of that place for
// the fragment's test against the buildings.

/// Mirrors RoadGlyphInput (RoadPathLabel.swift): a glyph's place in its
/// label.
struct RoadGlyphInput {
    pathIndex: u32,
    instanceIndex: u32,
    labelInstanceIndex: u32,
    _padding: u32,
    glyphCenter: f32,
    labelCenterY: f32,
    labelWidth: f32,
    spacing: f32,
    minLength: f32,
}

/// Mirrors RoadGlyphPlacementOutput (RoadPathLabel.swift): where the glyph
/// is drawn this frame.
struct RoadGlyphPlacementOutput {
    position: vec2f,
    angle: f32,
    visible: u32,
}

/// How far a glyph's place on the road moves toward the eye before its
/// depth is taken, as a fraction of the distance: clear of the ground it
/// lies on, without leaving its pixel.
const kRoadGlyphEyeStep = 0.01;

@group(0) @binding(1) var<uniform> matrix: mat4x4f;
@group(0) @binding(2) var<storage, read> placements: array<RoadGlyphPlacementOutput>;
@group(0) @binding(3) var<storage, read> glyphInputs: array<RoadGlyphInput>;
@group(0) @binding(4) var<storage, read> runtimeMeta: array<LabelRuntimeMeta>;
@group(0) @binding(5) var<uniform> globalGlyphShift: i32;
@group(0) @binding(6) var<uniform> screenOffset: vec2f;
@group(0) @binding(7) var<uniform> pixelsPerPoint: f32;
@group(0) @binding(8) var<uniform> scene: RoadLabelSceneDepthUniforms;

/// The depth of the road under a glyph: its pixel carried back along the
/// eye ray to the ground plane (z = 0), a step toward the eye, and
/// projected. 0 where there is no such point, which no depth is nearer
/// than, so nothing is cut.
fn roadGlyphAnchorDepth(pixel: vec2f) -> f32 {
    if (any(scene.viewportSize <= vec2f(0.0))) {
        return 0.0;
    }
    let ndc = pixel / scene.viewportSize * 2.0 - 1.0;
    let nearPoint = scene.inverseProjectionView * vec4f(ndc, 0.0, 1.0);
    let farPoint = scene.inverseProjectionView * vec4f(ndc, 0.5, 1.0);
    if (abs(nearPoint.w) < 1e-9 || abs(farPoint.w) < 1e-9) {
        return 0.0;
    }
    let a = nearPoint.xyz / nearPoint.w;
    let b = farPoint.xyz / farPoint.w;
    let heightChange = a.z - b.z;
    if (abs(heightChange) < 1e-9) {
        return 0.0;
    }
    let ground = a + (b - a) * (a.z / heightChange);
    let anchor = ground + (scene.eye - ground) * kRoadGlyphEyeStep;
    let clip = scene.projectionView * vec4f(anchor, 1.0);
    return select(0.0, clip.z / clip.w, clip.w > 0.0);
}

@vertex
fn roadLabelTextVertex(vertexIn: LabelVertexIn) -> RoadTextVertexOut {
    var out: RoadTextVertexOut;
    let glyphIndex = vertexIn.labelIndex + globalGlyphShift;
    let placement = placements[glyphIndex];
    let glyphInput = glyphInputs[glyphIndex];
    let labelState = runtimeMeta[glyphInput.labelInstanceIndex];

    // Glyph geometry is in layout points, the placement in device pixels.
    let local = (vertexIn.position - vec2f(glyphInput.glyphCenter, glyphInput.labelCenterY)) * pixelsPerPoint;
    let s = sin(placement.angle);
    let c = cos(placement.angle);
    let rotated = vec2f(local.x * c - local.y * s, local.x * s + local.y * c);
    let pixelPosition = placement.position + rotated + screenOffset;

    out.position = matrix * vec4f(pixelPosition, 0.0, 1.0);
    // Far-plane depth: the glyphs' own depths order them (TextShader.wgsl).
    out.position.z = out.position.w;
    out.uv = vertexIn.uv;
    let isVisible = placement.visible != 0u && labelState.fadeAlpha > 0.0;
    out.alpha = select(0.0, labelState.fadeAlpha, isVisible);
    if (!isVisible) {
        out.position = hiddenLabelClipPosition();
    }
    out.spriteUV = vertexIn.spriteUV;
    // The whole glyph stands where it touches the road, like a sign.
    out.anchorDepth = 0.0;
    if (scene.enabled != 0u && isVisible) {
        out.anchorDepth = roadGlyphAnchorDepth(placement.position);
    }
    return out;
}
