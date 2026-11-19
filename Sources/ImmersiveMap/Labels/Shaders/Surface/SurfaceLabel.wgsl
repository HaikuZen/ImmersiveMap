// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: SurfaceLabel.metal fnv1a64=96ec7b46b1ec434d
// include: ../../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../../Render/Shaders/Shared/GroundFog.wgsl
// include: ../../../Globe/Shaders/GlobeUnroll.wgsl
// include: ../../../Globe/Shaders/GlobeTransitionProjection.wgsl
// include: ../../../Globe/Shaders/GlobeTileProjection.wgsl

// The labels painted on the map (LabelPlacement.surface): glyph quads baked
// as an anchor in the tile's render units and offsets in points, scaled by
// the frame into tile units and projected exactly like the ground they lie
// on, by one vertex stage per surface. SurfaceLabel.metal explains them.
//
// Metal clips the unroll's cut with the hardware clip distance, which
// WebGPU has only behind the optional clip-distances feature: here the
// distance is an interpolated output and the fragment discards where it is
// negative, the same pixels the hardware would clip.

struct SurfaceLabelVertexIn {
    /// The label's anchor in tile render units.
    @location(0) anchor: vec2f,
    @location(1) uv: vec2f,
    /// The glyph corner's offset from the anchor in points.
    @location(2) offsetPoints: vec2f,
}

/// Per-draw tile identity of the sphere stages. Mirrors
/// GlobeSurfaceTileUniform.swift.
struct SurfaceLabelSphereTile {
    uvOrigin: vec2f,
    uvScale: f32,
    referenceWorldX: f32,
}

/// Per-draw label state. Mirrors SurfaceLabelDrawUniform.swift.
struct SurfaceLabelDraw {
    fillColor: vec4f,
    strokeColor: vec4f,
    /// The halo's width in atlas texels.
    haloAtlasTexels: f32,
    /// The clip-space depth the text sits at (SurfaceLabelDepth).
    depth: f32,
    /// 1 for the halo draw, 0 for the fill draw.
    haloPass: f32,
    /// Tile units per point of the text as the map scales it this frame.
    tileUnitsPerPoint: f32,
    viewportSizePx: vec2f,
    pixelsPerPoint: f32,
    /// The share of the halo's width over which it fades out.
    haloSoftness: f32,
}

struct SurfaceLabelVertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    /// The plane's point, for the ground fog. Unused on the sphere.
    @location(1) worldPosition: vec3f,
    /// Metal's clip distance: the fragment is dropped where it is negative.
    @location(2) clipDistance: f32,
}

const kSurfaceLabelTileExtent = 4096.0;
/// The camera's near plane in view units (kFlatCameraNearPlane in
/// Tile.metal): a label whose anchor or probe lies nearer is dropped.
const kSurfaceLabelNearPlane = 0.01;
/// RenderCamera.realDepthScale: the flat surface divides it out and applies
/// the label's own depth.
const kSurfaceLabelRealDepthScale = 1.0 - 1536.0 * 3.2e-6;
/// The atlas's distance range in texels (TextShader.wgsl).
const kSurfaceLabelDistanceRange = 24.0;
/// How far the scale probe reaches from the anchor, in points.
const kSurfaceLabelProbePoints = 16.0;

@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(3) var<uniform> modelMatrix: mat4x4f;
@group(0) @binding(4) var<uniform> draw: SurfaceLabelDraw;
@group(0) @binding(8) var<uniform> globe: Globe;
@group(0) @binding(9) var<uniform> tile: SurfaceLabelSphereTile;
@group(0) @binding(10) var<uniform> globeFrame: GlobeFrameConstants;

@group(1) @binding(0) var<uniform> fragmentDraw: SurfaceLabelDraw;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;
@group(1) @binding(16) var atlasTexture: texture_2d<f32>;
@group(1) @binding(49) var linearSampler: sampler;

fn surfaceLabelWorldUv(localPosition: vec2f) -> vec2f {
    let localUv = vec2f(localPosition.x, kSurfaceLabelTileExtent - localPosition.y) / kSurfaceLabelTileExtent;
    return tile.uvOrigin + localUv * tile.uvScale;
}

/// A point of the surface in clip space, with the clip distance its surface
/// cuts it by, and whether its depth is the projection's (the plane, the
/// morph) or a band at the far plane (the sphere).
struct SurfaceLabelClip {
    position: vec4f,
    worldPosition: vec3f,
    clipDistance: f32,
    projectedDepth: bool,
}

/// Screen pixels per tile unit around the anchor, the longer of the two
/// axes. Zero when the anchor or a probe is behind the camera.
fn surfaceLabelPixelsPerUnit(anchorClip: vec4f, alongX: vec4f, alongY: vec4f, probeUnits: f32) -> f32 {
    if (anchorClip.w <= kSurfaceLabelNearPlane || alongX.w <= kSurfaceLabelNearPlane
        || alongY.w <= kSurfaceLabelNearPlane) {
        return 0.0;
    }
    let anchorScreen = anchorClip.xy / anchorClip.w;
    let halfViewport = draw.viewportSizePx * 0.5;
    let spanX = length((alongX.xy / alongX.w - anchorScreen) * halfViewport);
    let spanY = length((alongY.xy / alongY.w - anchorScreen) * halfViewport);
    return max(spanX, spanY) / probeUnits;
}

/// Tile units per point of the text at this frame: the map's own scale, but
/// never smaller on screen than the style's point size.
fn surfaceLabelUnitsPerPoint(pixelsPerUnit: f32) -> f32 {
    if (pixelsPerUnit <= 0.0) {
        return draw.tileUnitsPerPoint;
    }
    return max(draw.tileUnitsPerPoint, draw.pixelsPerPoint / pixelsPerUnit);
}

/// Where the glyph corner lies, in tile units: the anchor plus its offset
/// at the scale the four probes measured.
fn surfaceLabelLocal(vertexIn: SurfaceLabelVertexIn, anchorClip: vec4f, alongX: vec4f, alongY: vec4f) -> vec2f {
    let probeUnits = draw.tileUnitsPerPoint * kSurfaceLabelProbePoints;
    let pixelsPerUnit = surfaceLabelPixelsPerUnit(anchorClip, alongX, alongY, probeUnits);
    return vertexIn.anchor + vertexIn.offsetPoints * surfaceLabelUnitsPerPoint(pixelsPerUnit);
}

fn surfaceLabelProbe() -> f32 {
    return draw.tileUnitsPerPoint * kSurfaceLabelProbePoints;
}

fn surfaceLabelOutput(clip: SurfaceLabelClip, uv: vec2f) -> SurfaceLabelVertexOut {
    var out: SurfaceLabelVertexOut;
    out.position = clip.position;
    if (clip.projectedDepth) {
        out.position.z = clip.position.z * (draw.depth / kSurfaceLabelRealDepthScale);
    } else {
        out.position.z = draw.depth * out.position.w;
    }
    out.uv = uv;
    out.worldPosition = clip.worldPosition;
    out.clipDistance = clip.clipDistance;
    return out;
}

// Each surface's projection of a tile-local point, the ground's own.

fn surfaceLabelFlatClip(local: vec2f) -> SurfaceLabelClip {
    var clip: SurfaceLabelClip;
    let worldPosition = modelMatrix * vec4f(local, 0.0, 1.0);
    clip.position = camera.matrix * worldPosition;
    clip.worldPosition = worldPosition.xyz;
    // The depth is the projection's, so the near plane clips, as for the
    // ground.
    clip.clipDistance = 1.0;
    clip.projectedDepth = true;
    return clip;
}

fn surfaceLabelSphereClip(local: vec2f) -> SurfaceLabelClip {
    var clip: SurfaceLabelClip;
    let unitDirection = globeWorldUVUnitDirection(surfaceLabelWorldUv(local));
    clip.position = globeFrame.sphereClip * vec4f(unitDirection, 1.0);
    clip.worldPosition = vec3f(0.0);
    // The far side of the planet goes to back-face culling.
    clip.clipDistance = 1.0;
    clip.projectedDepth = false;
    return clip;
}

fn surfaceLabelMorphClip(local: vec2f) -> SurfaceLabelClip {
    let worldUv = surfaceLabelWorldUv(local);
    let unitDirection = globeWorldUVUnitDirection(worldUv);
    let sphereWorldPosition = (globeFrame.sphereWorld * vec4f(unitDirection, 1.0)).xyz;
    let mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    let flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                             globeFrame.mapSize, globeFrame.panMercatorY,
                                                             tile.referenceWorldX);
    let worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition, globe.transition, globe.radius);
    var clip: SurfaceLabelClip;
    clip.position = camera.matrix * vec4f(worldPosition, 1.0);
    clip.worldPosition = worldPosition;
    clip.clipDistance = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition, globe.transition, globe.radius);
    clip.projectedDepth = true;
    return clip;
}

// The three stages: measure the scale at the anchor, then place the glyph
// corner at its offset from it, each through its surface's projection.

@vertex
fn surfaceLabelFlatVertex(vertexIn: SurfaceLabelVertexIn) -> SurfaceLabelVertexOut {
    let probe = surfaceLabelProbe();
    let local = surfaceLabelLocal(vertexIn,
                                  surfaceLabelFlatClip(vertexIn.anchor).position,
                                  surfaceLabelFlatClip(vertexIn.anchor + vec2f(probe, 0.0)).position,
                                  surfaceLabelFlatClip(vertexIn.anchor + vec2f(0.0, probe)).position);
    return surfaceLabelOutput(surfaceLabelFlatClip(local), vertexIn.uv);
}

@vertex
fn surfaceLabelSphereVertex(vertexIn: SurfaceLabelVertexIn) -> SurfaceLabelVertexOut {
    let probe = surfaceLabelProbe();
    let local = surfaceLabelLocal(vertexIn,
                                  surfaceLabelSphereClip(vertexIn.anchor).position,
                                  surfaceLabelSphereClip(vertexIn.anchor + vec2f(probe, 0.0)).position,
                                  surfaceLabelSphereClip(vertexIn.anchor + vec2f(0.0, probe)).position);
    return surfaceLabelOutput(surfaceLabelSphereClip(local), vertexIn.uv);
}

@vertex
fn surfaceLabelMorphVertex(vertexIn: SurfaceLabelVertexIn) -> SurfaceLabelVertexOut {
    let probe = surfaceLabelProbe();
    let local = surfaceLabelLocal(vertexIn,
                                  surfaceLabelMorphClip(vertexIn.anchor).position,
                                  surfaceLabelMorphClip(vertexIn.anchor + vec2f(probe, 0.0)).position,
                                  surfaceLabelMorphClip(vertexIn.anchor + vec2f(0.0, probe)).position);
    return surfaceLabelOutput(surfaceLabelMorphClip(local), vertexIn.uv);
}

/// The glyph's distance fields in screen pixels, the pixel range from the
/// uv derivatives (computeTextDistance in TextShader.wgsl).
@fragment
fn surfaceLabelFragment(in: SurfaceLabelVertexOut) -> @location(0) vec4f {
    // The unroll's cut, which Metal's hardware clip distance makes.
    if (in.clipDistance < 0.0) {
        discard;
    }
    let atlasSample = textureSample(atlasTexture, linearSampler, in.uv);
    let msdf = atlasSample.rgb;
    let msdfDistance = max(min(msdf.r, msdf.g), min(max(msdf.r, msdf.g), msdf.b)) - 0.5;
    let sdfDistance = atlasSample.a - 0.5;
    let textureSize = vec2f(textureDimensions(atlasTexture));
    let unitRange = vec2f(kSurfaceLabelDistanceRange) / textureSize;
    let screenTextureSize = 1.0 / max(fwidth(in.uv), vec2f(1e-6));
    let screenPxRange = max(0.5 * dot(unitRange, screenTextureSize), 1.0);
    // Screen pixels per atlas texel.
    let pixelsPerTexel = screenPxRange / kSurfaceLabelDistanceRange;

    var coverage: f32;
    var color: vec3f;
    // The style's opacity rides in the colours' alpha.
    var opacity: f32;
    if (fragmentDraw.haloPass > 0.5) {
        // The halo reaches past the glyph by its width, bounded by the
        // distance field's support.
        let haloPx = min(fragmentDraw.haloAtlasTexels * pixelsPerTexel, max(0.5 * screenPxRange - 0.5, 0.0));
        if (haloPx <= 0.0) {
            discard;
        }
        let fadePx = haloPx * fragmentDraw.haloSoftness;
        coverage = smoothstep(-haloPx - 0.5, -haloPx + 0.5 + fadePx, sdfDistance * screenPxRange);
        color = fragmentDraw.strokeColor.rgb;
        opacity = fragmentDraw.strokeColor.a;
    } else {
        // The point labels' weight bias (textFragment), so a name reads the
        // same on the map as on the screen.
        let boldBiasPx = 0.75;
        coverage = smoothstep(-0.5, 0.5, msdfDistance * screenPxRange + boldBiasPx);
        color = fragmentDraw.fillColor.rgb;
        opacity = fragmentDraw.fillColor.a;
    }
    let alpha = coverage * opacity;
    if (alpha <= 0.0) {
        discard;
    }
    return vec4f(applyGroundFog(color, in.worldPosition, groundFog), alpha);
}
