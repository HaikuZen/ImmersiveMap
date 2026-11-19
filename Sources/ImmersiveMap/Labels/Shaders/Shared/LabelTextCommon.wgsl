// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: LabelTextCommon.h fnv1a64=1c8b7c30f195efc4
// ported-from: LabelRuntimeMeta.h fnv1a64=7a582d73d3f2bbf5

// What the label shaders share: the label vertex, the screen points the
// labels hang off, the per-label state written every frame, the vertex
// outputs the glyph fragments read, and the road names' world depth.

/// Mirrors LabelVertex: a glyph's corner in layout points, its atlas uv,
/// the label it belongs to and its place on a POI plate.
struct LabelVertexIn {
    @location(0) position: vec2f,
    @location(1) uv: vec2f,
    @location(2) labelIndex: i32,
    @location(3) spriteUV: vec2f,
}

/// Mirrors ScreenPointOutput.swift.
struct ScreenPointOutput {
    position: vec2f,
    depth: f32,
    visible: u32,
    visibilityAlpha: f32,
}

/// Mirrors LabelRuntimeMeta.swift: 16 bytes per label, written every frame.
struct LabelRuntimeMeta {
    fadeAlpha: f32,
    /// The label's shrink for its distance.
    perspectiveScale: f32,
    labelSizePoints: vec2f,
}

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) alpha: f32,
    @location(2) spriteUV: vec2f,
}

/// A road glyph's vertex output: VertexOut plus the depth of the glyph's
/// place on the road, which the fragment tests the world's depth against.
struct RoadTextVertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) alpha: f32,
    @location(2) spriteUV: vec2f,
    @location(3) @interpolate(flat) anchorDepth: f32,
}

/// The world's depth for the road names. Mirrors
/// RoadLabelSceneDepthUniforms.swift. With `enabled` 0 nothing is tested.
struct RoadLabelSceneDepthUniforms {
    projectionView: mat4x4f,
    inverseProjectionView: mat4x4f,
    @size(16) eye: vec3f,
    viewportSize: vec2f,
    enabled: u32,
}

/// The clip position of a hidden label's vertices: outside the clip volume
/// on one side, so the rasterizer rejects the primitive whole.
fn hiddenLabelClipPosition() -> vec4f {
    return vec4f(-2.0, -2.0, 0.0, 1.0);
}

/// A label quad's vertex, hung off its screen point (labelTextVertex,
/// poiSpriteVertex): glyph geometry and the collision box are in layout
/// points, the screen point in device pixels, and the label shrinks about
/// its anchor for its distance. At the far plane, so the cleared overlay
/// depth passes and the glyphs' own depths order them (TextShader.wgsl).
fn labelQuadVertex(vertexIn: LabelVertexIn,
                   matrix: mat4x4f,
                   screenPoint: ScreenPointOutput,
                   runtimeState: LabelRuntimeMeta,
                   pixelsPerPoint: f32) -> VertexOut {
    var out: VertexOut;
    let halfSize = runtimeState.labelSizePoints * 0.5;
    let pixelPosition = screenPoint.position
        + (vertexIn.position - halfSize) * (pixelsPerPoint * runtimeState.perspectiveScale);
    out.position = matrix * vec4f(pixelPosition, 0.0, 1.0);
    out.position.z = out.position.w;
    out.uv = vertexIn.uv;
    let isVisible = screenPoint.visible != 0u && runtimeState.fadeAlpha > 0.0;
    out.alpha = select(0.0, runtimeState.fadeAlpha, isVisible);
    if (!isVisible) {
        out.position = hiddenLabelClipPosition();
    }
    out.spriteUV = vertexIn.spriteUV;
    return out;
}
