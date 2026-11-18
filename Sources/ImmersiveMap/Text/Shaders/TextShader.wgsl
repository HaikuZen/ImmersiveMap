// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: TextShader.metal fnv1a64=7c2323606dbba7ad
// include: ../../Labels/Shaders/Shared/LabelTextCommon.wgsl

// The text of the labels: the glyphs drawn from the MTSDF atlas, the fill
// from the multi-channel distance and the halo from the plain one, fill and
// halo in one pass ordered by depth. TextShader.metal explains the fields.

struct VertexIn {
    @location(0) position: vec4f,
    @location(1) uv: vec2f,
}

/// Mirrors TextStyleUniform.
struct TextStyle {
    @size(16) textColor: vec3f,
    /// How far the letters are grown past the font's outline, in pixels.
    fillBiasPx: f32,
    @size(16) strokeColor: vec3f,
    strokeWidthPx: f32,
    /// The opacity of the fill and the halo, 1 solid.
    opacity: f32,
    /// The share of the halo's width, in from its outer edge, over which it
    /// fades out, 0 solid to its edge.
    haloSoftness: f32,
}

struct TextDistance {
    msdfPxDist: f32,
    sdfPxDist: f32,
    screenPxRange: f32,
}

/// The label fragment's colour and its depth: a fill fragment writes the
/// nearer of two far-plane depths and a halo fragment the farther, under
/// less-equal with depth write on, so a halo never lands on a fill already
/// there while a fill still lands on a halo. A fragment with no coverage
/// writes the far plane itself, which changes nothing.
struct TextFragmentOut {
    @location(0) color: vec4f,
    @builtin(frag_depth) depth: f32,
}

const kLabelFillDepth = 0.99999976;
const kLabelHaloDepth = 0.99999988;
const kDistanceRange = 24.0;

@group(0) @binding(1) var<uniform> matrix: mat4x4f;

@group(1) @binding(0) var<uniform> style: TextStyle;
@group(1) @binding(1) var<uniform> scene: RoadLabelSceneDepthUniforms;
@group(1) @binding(16) var atlasTexture: texture_2d<f32>;
@group(1) @binding(17) var sceneDepth: texture_depth_2d;
@group(1) @binding(49) var linearSampler: sampler;

@vertex
fn textVertex(vertexIn: VertexIn) -> VertexOut {
    var out: VertexOut;
    out.position = matrix * vertexIn.position;
    out.uv = vertexIn.uv;
    out.alpha = 1.0;
    out.spriteUV = vec2f(0.0);
    return out;
}

/// The distances to the glyph's edge in screen pixels, and how many pixels
/// the atlas's distance range spans on screen.
fn computeTextDistance(uv: vec2f) -> TextDistance {
    let atlasSample = textureSample(atlasTexture, linearSampler, uv);
    let msdf = atlasSample.rgb;
    let sd = max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b)) - 0.5;
    let sdf = atlasSample.a - 0.5;
    let texSize = vec2f(textureDimensions(atlasTexture));
    let unitRange = vec2f(kDistanceRange) / texSize;
    let duv = max(fwidth(uv), vec2f(1e-6));
    let screenTexSize = 1.0 / duv;
    let screenPxRange = max(0.5 * dot(unitRange, screenTexSize), 1.0);
    var distance: TextDistance;
    distance.msdfPxDist = sd * screenPxRange;
    distance.sdfPxDist = sdf * screenPxRange;
    distance.screenPxRange = screenPxRange;
    return distance;
}

fn shadeGlyph(distance: TextDistance, fillPxDist: f32, strokeWidthPx: f32, vertexAlpha: f32) -> TextFragmentOut {
    let fill = smoothstep(-0.5, 0.5, fillPxDist);
    // The halo fades in from its end over its softness's share of its width.
    let fadePx = strokeWidthPx * style.haloSoftness;
    let outer = smoothstep(-strokeWidthPx - 0.5, -strokeWidthPx + 0.5 + fadePx, distance.sdfPxDist);
    // A style that asks for no halo gets none, exactly.
    var stroke = 0.0;
    if (strokeWidthPx > 0.0) {
        stroke = clamp(outer - fill, 0.0, 1.0);
    }

    let coverage = clamp(fill + stroke, 0.0, 1.0);
    let alpha = coverage * vertexAlpha * style.opacity;
    let color = (fill * style.textColor + stroke * style.strokeColor) / max(coverage, 1.0e-4);
    var out: TextFragmentOut;
    out.color = vec4f(color, alpha);
    out.depth = 1.0;
    if (fill > 0.0) {
        out.depth = kLabelFillDepth;
    } else if (stroke > 0.0) {
        out.depth = kLabelHaloDepth;
    }
    return out;
}

@fragment
fn textFragment(in: VertexOut) -> TextFragmentOut {
    let distance = computeTextDistance(in.uv);
    // Point labels sit on textured terrain, so keep the halo narrow enough
    // that large style values cannot fill the glyph quad.
    let maxStrokePx = max(0.5 * distance.screenPxRange - 0.5, 0.0);
    let strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    return shadeGlyph(distance, distance.msdfPxDist + style.fillBiasPx, strokeWidthPx, in.alpha);
}

@fragment
fn roadTextFragment(roadIn: RoadTextVertexOut) -> TextFragmentOut {
    // The buildings and the models paint over the road names behind them:
    // a pixel of the name is dropped where the world pass drew something
    // nearer than the glyph's place on the road.
    if (scene.enabled != 0u) {
        let pixel = vec2u(roadIn.position.xy);
        let size = textureDimensions(sceneDepth);
        if (pixel.x < size.x && pixel.y < size.y && textureLoad(sceneDepth, pixel, 0) < roadIn.anchorDepth) {
            discard;
        }
    }

    var distance = computeTextDistance(roadIn.uv);

    // A road label is rotated along its road, and fwidth sums the uv
    // derivatives of both screen axes, so the range here comes from the
    // length of the derivatives instead, the same at every angle, and the
    // distances are rescaled to it.
    let texSize = vec2f(textureDimensions(atlasTexture));
    let texelsPerPixelX = dpdx(roadIn.uv) * texSize;
    let texelsPerPixelY = dpdy(roadIn.uv) * texSize;
    let texelsPerPixel = sqrt(0.5 * (dot(texelsPerPixelX, texelsPerPixelX) + dot(texelsPerPixelY, texelsPerPixelY)));
    let screenPxRange = max(kDistanceRange / max(texelsPerPixel, 1e-6), 1.0);
    let rescale = screenPxRange / distance.screenPxRange;
    distance.msdfPxDist *= rescale;
    distance.sdfPxDist *= rescale;
    distance.screenPxRange = screenPxRange;

    // The halo stays inside the distance field's support, half the range
    // past the glyph edge.
    let maxStrokePx = max(0.5 * distance.screenPxRange - 0.5, 0.0);
    let strokeWidthPx = min(style.strokeWidthPx, maxStrokePx);
    return shadeGlyph(distance, distance.msdfPxDist + style.fillBiasPx, strokeWidthPx, roadIn.alpha);
}
