// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: PinRender.metal fnv1a64=b3ee67e379e63a27
// include: PinCommon.wgsl

// The pins' bodies, their frame cut from the shape's distance field, and
// the merged pins' counters.

@group(0) @binding(0) var<uniform> screenMatrix: mat4x4f;
@group(0) @binding(1) var<storage, read> points: array<ScreenPointOutput>;
@group(0) @binding(2) var<storage, read> instances: array<PinInstanceGPU>;
@group(0) @binding(2) var<storage, read> badgeInstances: array<PinCountBadgeInstanceGPU>;
@group(0) @binding(3) var<uniform> vertexStyle: PinStyleGPU;
@group(0) @binding(3) var<uniform> badgeStyle: PinCountBadgeStyleGPU;

@group(1) @binding(0) var<uniform> style: PinStyleGPU;
@group(1) @binding(16) var atlasTexture: texture_2d_array<f32>;
@group(1) @binding(16) var badgeAtlas: texture_2d<f32>;
@group(1) @binding(17) var sdfTexture: texture_2d<f32>;
@group(1) @binding(49) var linearSampler: sampler;

struct PinVertexOut {
    @builtin(position) position: vec4f,
    @location(0) uvLocal: vec2f,
    @location(1) uvRect: vec4f,
    @location(2) borderColor: vec4f,
    @location(3) visibilityAlpha: f32,
    @location(4) morph: f32,
    @location(5) @interpolate(flat) atlasIndex: u32,
    @location(6) @interpolate(flat) flags: u32,
}

fn decodeSignedDistanceTexels(encodedDistance: f32, distanceRangeTexels: f32) -> f32 {
    return (0.5 - encodedDistance) * (2.0 * distanceRangeTexels);
}

@vertex
fn pinVertex(@builtin(vertex_index) vid: u32,
             @builtin(instance_index) iid: u32) -> PinVertexOut {
    var out: PinVertexOut;
    let instance = instances[iid];
    let point = points[iid];
    if (point.visible == 0u) {
        out.position = vec4f(-2.0, -2.0, 0.0, 1.0);
        out.uvLocal = vec2f(0.0);
        out.uvRect = vec4f(0.0);
        out.borderColor = vec4f(0.0);
        out.visibilityAlpha = 0.0;
        out.morph = 0.0;
        out.atlasIndex = 0u;
        out.flags = 0u;
        return out;
    }
    // The quad is laid so that the shape's anchor stands on the pin's point.
    let uv = pinQuadCorner(vid);
    let local = (uv - vertexStyle.anchorUv) * vertexStyle.sizePx * instance.squashScale;
    let pixelPosition = point.position + local;

    out.position = screenMatrix * vec4f(pixelPosition, 0.0, 1.0);
    out.uvLocal = uv;
    out.uvRect = instance.uvRect;
    out.borderColor = instance.borderColor;
    out.visibilityAlpha = point.visibilityAlpha;
    out.morph = instance.morph;
    out.atlasIndex = instance.atlasIndex;
    out.flags = instance.flags;
    return out;
}

// Metal runs the sampling and the masks' composition in half. WGSL has f32
// alone (f16 is optional). The pipeline blends by the source's alpha, so
// the color leaves the shader not multiplied by it.
@fragment
fn pinFragment(in: PinVertexOut) -> @location(0) vec4f {
    // A pin without a frame is its picture alone, cut by the picture's alpha.
    // Sampled before the branch, as WGSL asks a sample to be in uniform
    // control flow.
    let pictureUv = mix(in.uvRect.xy, in.uvRect.zw, in.uvLocal);
    let picture = textureSample(atlasTexture, linearSampler, pictureUv, in.atlasIndex);

    let sdfUv = vec2f(in.uvLocal.x, 1.0 - in.uvLocal.y);
    // A baked shape keeps its distance in red, the built-in bubble in alpha.
    let sdfSample = textureSample(sdfTexture, linearSampler, sdfUv);
    let sdfTextureSize = vec2f(textureDimensions(sdfTexture));
    let texelsPerPixelX = length(dpdx(in.uvLocal) * sdfTextureSize);
    let texelsPerPixelY = length(dpdy(in.uvLocal) * sdfTextureSize);

    // The picture is laid into the picture area, set in by the inset, and is
    // centered on the circle a pushed pin turns into.
    let circleCenter = style.bodyCenterUv;
    let insetUv = vec2f(style.contentInsetPx) / max(style.sizePx, vec2f(1.0));
    let contentHalfUv = max(style.bodyHalfUv - insetUv, vec2f(0.0001));
    let imageUv = clamp((in.uvLocal - (circleCenter - contentHalfUv)) / (2.0 * contentHalfUv), vec2f(0.0), vec2f(1.0));
    let atlasUv = mix(in.uvRect.xy, in.uvRect.zw, imageUv);
    let tex = textureSample(atlasTexture, linearSampler, atlasUv, in.atlasIndex);

    if (style.frameless != 0u) {
        return vec4f(picture.rgb / max(picture.a, 0.0001), picture.a * in.visibilityAlpha);
    }

    var encodedDistance = sdfSample.r;
    if (style.distanceInAlpha != 0u) {
        encodedDistance = sdfSample.a;
    }
    let pinDistanceTexels = decodeSignedDistanceTexels(encodedDistance, style.distanceRangeTexels);
    // Pin -> circle morph: an analytic SDF of the body circle in the same
    // texels as the shape's sample, so the masks below stay unchanged.
    let circleRadiusTexels = style.circleRadiusUv * sdfTextureSize.x;
    let circleDistanceTexels = length((in.uvLocal - circleCenter) * sdfTextureSize) - circleRadiusTexels;
    let shapeDistanceTexels = mix(pinDistanceTexels, circleDistanceTexels, saturate(in.morph));
    let texelsPerPixel = max(max(texelsPerPixelX, texelsPerPixelY), 0.0001);
    let edgeWidthTexels = max(0.75 * texelsPerPixel, 0.75);
    let outlineWidthTexels = max(style.outlineWidthPx * texelsPerPixel, edgeWidthTexels);
    let fillMask = 1.0 - smoothstep(-edgeWidthTexels, edgeWidthTexels, shapeDistanceTexels);
    // An outline of no width is no outline, not a hairline.
    var borderMask = 0.0;
    if (style.outlineWidthPx > 0.0) {
        borderMask = smoothstep(-outlineWidthTexels - edgeWidthTexels, -edgeWidthTexels, shapeDistanceTexels) * fillMask;
    }
    let interiorMask = max(fillMask - borderMask, 0.0);
    var outlineInset = 0.0;
    if (style.outlineWidthPx > 0.0) {
        outlineInset = outlineWidthTexels + edgeWidthTexels;
    }
    let contentInsetTexels = max(style.contentInsetPx * texelsPerPixel, outlineInset);
    var imageMask = 1.0 - smoothstep(-contentInsetTexels - edgeWidthTexels,
                                     -contentInsetTexels + edgeWidthTexels,
                                     shapeDistanceTexels);
    imageMask *= interiorMask;

    // Everything below is multiplied by its own alpha until the last line.
    let fill = vec4f(style.fillColor.rgb * style.fillColor.a, style.fillColor.a);
    let outline = vec4f(in.borderColor.rgb * in.borderColor.a, in.borderColor.a);
    // A picture with transparent parts lies on the fill, not on the map.
    let pictureOnFill = tex + fill * (1.0 - tex.a);
    let fillBandMask = max(interiorMask - imageMask, 0.0);
    let color = pictureOnFill * imageMask + fill * fillBandMask + outline * borderMask;
    return vec4f(color.rgb / max(color.a, 0.0001), color.a * in.visibilityAlpha);
}

struct PinCountBadgeVertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    @location(1) uvRect: vec4f,
    @location(2) visibilityAlpha: f32,
    @location(3) contentAlpha: f32,
}

@vertex
fn pinCountBadgeVertex(@builtin(vertex_index) vid: u32,
                       @builtin(instance_index) iid: u32) -> PinCountBadgeVertexOut {
    var out: PinCountBadgeVertexOut;
    let instance = badgeInstances[iid];
    let point = points[iid];
    if (point.visible == 0u || (instance.flags & 1u) == 0u || instance.contentAlpha <= 0.0) {
        out.position = vec4f(-2.0, -2.0, 0.0, 1.0);
        out.uv = vec2f(0.0);
        out.uvRect = vec4f(0.0);
        out.visibilityAlpha = 0.0;
        out.contentAlpha = 0.0;
        return out;
    }

    let uv = pinQuadCorner(vid);
    let screenSizeScale = max(instance.screenSizeScale, 0.0);
    let local = vec2f(badgeStyle.originXPx * screenSizeScale + uv.x * badgeStyle.sizePx.x * screenSizeScale,
                      badgeStyle.originYPx * screenSizeScale + uv.y * badgeStyle.sizePx.y * screenSizeScale);
    let pixelPosition = point.position + local;

    out.position = screenMatrix * vec4f(pixelPosition, 0.0, 1.0);
    out.uv = uv;
    out.uvRect = instance.uvRect;
    out.visibilityAlpha = point.visibilityAlpha;
    out.contentAlpha = instance.contentAlpha;
    return out;
}

@fragment
fn pinCountBadgeFragment(in: PinCountBadgeVertexOut) -> @location(0) vec4f {
    let uv = mix(in.uvRect.xy, in.uvRect.zw, in.uv);
    var color = textureSample(badgeAtlas, linearSampler, uv);
    color.a *= in.visibilityAlpha * in.contentAlpha;
    return color;
}
