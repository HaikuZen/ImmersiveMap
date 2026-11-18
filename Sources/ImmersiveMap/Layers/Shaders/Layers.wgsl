// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: Layers.metal fnv1a64=98e3bb7345c1763c
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl
// include: ../../Globe/Shaders/GlobeUnroll.wgsl
// include: ../../Globe/Shaders/GlobeTransitionProjection.wgsl
// include: ../../Globe/Shaders/GlobeTileProjection.wgsl
// include: ../../Globe/Shaders/GlobeLight.wgsl

// The layers of the app's data (ImmersiveMapLayer): zones, lines and points
// lying on the ground, each vertex projected the ground's own way on the
// surface the frame draws. A zone is its triangles, a line an instance
// per segment, a shape of the screen with round ends, solid and drawn
// without blending, a point a disc with a ring. Layers.metal explains
// them.
//
// The vertices are read from a storage buffer by the vertex or instance
// index. Their colours are Metal's uchar4, four bytes red first, which WGSL
// reads as one u32 and unpacks. Metal's hardware clip distance is an
// interpolated output the fragment discards on where it is negative.

/// The surface the frame draws: 0 the flat map, 1 the resting sphere, 2
/// the unfurl. Mirrors LayerPipeline.Surface.
@id(0) override kLayerSurface: i32;
const kLayerSurfaceFlat = 0;
const kLayerSurfaceSphere = 1;

const kLayerTileExtent = 4096.0;
/// RenderCamera.realDepthScale: the flat surface and the unfurl divide it
/// out and apply the layer's own depth.
const kLayerRealDepthScale = 1.0 - 1536.0 * 3.2e-6;
/// A vertex nearer the camera than this in clip w is behind it.
const kLayerNearW = 1.0e-4;

/// Mirrors LayerFillVertex in LayerMeshBuilder.swift.
struct LayerFillVertex {
    position: vec2f,
    color: u32,
}

/// Mirrors LayerLineSegment in LayerMeshBuilder.swift. The colour's
/// fourth byte is not an alpha, a line is always solid: it states which
/// ends are round, 1 for the start and 2 for the end.
struct LayerLineSegment {
    start: vec2f,
    end: vec2f,
    widthPoints: f32,
    color: u32,
}

/// The corners of a segment's shape, the same for every segment
/// (`LayerPipeline.lineTemplateIndices` joins them into triangles): which
/// end of the segment the corner is at, then how far it stands from that
/// end along the segment (outward is positive) and across it, in half
/// widths. Each end is half an octagon, standing for a half disc.
const kLayerLineCorners = array<vec3f, 10>(
    vec3f(0.0, 0.0, -1.0), vec3f(0.0, 0.0, 1.0),
    vec3f(0.0, 0.70710678, -0.70710678), vec3f(0.0, 0.70710678, 0.70710678), vec3f(0.0, 1.0, 0.0),
    vec3f(1.0, 0.0, -1.0), vec3f(1.0, 0.0, 1.0),
    vec3f(1.0, 0.70710678, -0.70710678), vec3f(1.0, 0.70710678, 0.70710678), vec3f(1.0, 1.0, 0.0)
);

/// Mirrors LayerPointInstance in LayerMeshBuilder.swift.
struct LayerPointInstance {
    position: vec2f,
    radiusPoints: f32,
    strokeWidthPoints: f32,
    color: u32,
    strokeColor: u32,
}

/// Per-chunk draw state. Mirrors LayerDrawUniform in LayerPipeline.swift.
struct LayerDraw {
    /// The chunk's flat model matrix (the flat surface).
    modelMatrix: mat4x4f,
    /// The chunk tile's world uv origin and size, and the world x the
    /// unfurl unwraps it around (the sphere and the unfurl).
    uvOrigin: vec2f,
    uvScale: f32,
    referenceWorldX: f32,
    viewportSizePx: vec2f,
    pixelsPerPoint: f32,
    /// The clip-space depth the layer lies at (LayerDepth).
    depth: f32,
}

@group(0) @binding(0) var<storage, read> fillVertices: array<LayerFillVertex>;
@group(0) @binding(0) var<storage, read> lineSegments: array<LayerLineSegment>;
@group(0) @binding(0) var<storage, read> pointInstances: array<LayerPointInstance>;
@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(2) var<uniform> draw: LayerDraw;
@group(0) @binding(8) var<uniform> globe: Globe;
@group(0) @binding(10) var<uniform> globeFrame: GlobeFrameConstants;

@group(1) @binding(9) var<uniform> globeLight: GlobeLight;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;

/// A point of the surface in clip space, with what the fragment needs. The
/// clip distance is negative where the surface hides the point.
struct LayerClip {
    position: vec4f,
    worldPosition: vec3f,
    sphereNormal: vec3f,
    clipDistance: f32,
}

fn layerProject(local: vec2f) -> LayerClip {
    var clip: LayerClip;
    if (kLayerSurface == kLayerSurfaceFlat) {
        let worldPosition = draw.modelMatrix * vec4f(local, 0.0, 1.0);
        clip.position = camera.matrix * worldPosition;
        clip.position.z *= draw.depth / kLayerRealDepthScale;
        clip.worldPosition = worldPosition.xyz;
        clip.sphereNormal = vec3f(0.0, 0.0, 1.0);
        clip.clipDistance = 1.0;
        return clip;
    }
    let localUv = vec2f(local.x, kLayerTileExtent - local.y) / kLayerTileExtent;
    let worldUv = draw.uvOrigin + localUv * draw.uvScale;
    let unitDirection = globeWorldUVUnitDirection(worldUv);
    let sphereWorldPosition = (globeFrame.sphereWorld * vec4f(unitDirection, 1.0)).xyz;
    clip.sphereNormal = (globeFrame.sphereWorld * vec4f(unitDirection, 0.0)).xyz;
    if (kLayerSurface == kLayerSurfaceSphere) {
        clip.position = globeFrame.sphereClip * vec4f(unitDirection, 1.0);
        clip.position.z = draw.depth * clip.position.w;
        clip.worldPosition = sphereWorldPosition;
        // The far side of the planet: every vertex is cut where the sphere
        // turns away from the eye, as a line's and a point's quads face
        // the camera.
        clip.clipDistance = dot(normalize(clip.sphereNormal), normalize(camera.eye - sphereWorldPosition));
        return clip;
    }
    let mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    let flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                             globeFrame.mapSize, globeFrame.panMercatorY,
                                                             draw.referenceWorldX);
    let worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition, globe.transition, globe.radius);
    clip.position = camera.matrix * vec4f(worldPosition, 1.0);
    clip.position.z *= draw.depth / kLayerRealDepthScale;
    clip.worldPosition = worldPosition;
    clip.clipDistance = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition, globe.transition, globe.radius);
    return clip;
}

/// The colour as the ground under it is lit: the globe's sun on the sphere
/// and through the unfurl, the ground fog on the plane.
fn layerShade(color: vec4f, worldPosition: vec3f, sphereNormal: vec3f) -> vec4f {
    var rgb = color.rgb;
    if (kLayerSurface != kLayerSurfaceFlat) {
        rgb = globeLitColor(rgb, sphereNormal, globeLight);
    }
    return vec4f(applyGroundFog(rgb, worldPosition, groundFog), color.a);
}

// MARK: - Zones

struct LayerFillOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    @location(1) sphereNormal: vec3f,
    @location(2) color: vec4f,
    @location(3) clipDistance: f32,
}

@vertex
fn layerFillVertex(@builtin(vertex_index) vertexID: u32) -> LayerFillOut {
    let vertexIn = fillVertices[vertexID];
    let clip = layerProject(vertexIn.position);
    var out: LayerFillOut;
    out.position = clip.position;
    // The fill keeps the sphere's back-face culling for the far side. The
    // cut is the unfurl's alone.
    out.clipDistance = select(clip.clipDistance, 1.0, kLayerSurface == kLayerSurfaceSphere);
    out.worldPosition = clip.worldPosition;
    out.sphereNormal = clip.sphereNormal;
    out.color = unpack4x8unorm(vertexIn.color);
    return out;
}

@fragment
fn layerFillFragment(in: LayerFillOut) -> @location(0) vec4f {
    if (in.clipDistance < 0.0) {
        discard;
    }
    return layerShade(in.color, in.worldPosition, in.sphereNormal);
}

// MARK: - Lines

struct LayerLineOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    @location(1) sphereNormal: vec3f,
    @location(2) color: vec4f,
    @location(3) clipDistance: f32,
}

@vertex
fn layerLineVertex(@builtin(vertex_index) vertexID: u32,
                   @builtin(instance_index) instanceID: u32) -> LayerLineOut {
    let segment = lineSegments[instanceID];
    let start = layerProject(segment.start);
    let end = layerProject(segment.end);
    // An end behind the camera is pulled to just before it along the
    // segment, so the shape's direction on screen stays the segment's.
    var startClip = start.position;
    var endClip = end.position;
    if (startClip.w < kLayerNearW && endClip.w > kLayerNearW) {
        startClip = mix(startClip, endClip, (kLayerNearW - startClip.w) / (endClip.w - startClip.w));
    } else if (endClip.w < kLayerNearW && startClip.w > kLayerNearW) {
        endClip = mix(endClip, startClip, (kLayerNearW - endClip.w) / (startClip.w - endClip.w));
    }
    let halfViewport = draw.viewportSizePx * 0.5;
    let startScreen = startClip.xy / max(startClip.w, kLayerNearW) * halfViewport;
    let endScreen = endClip.xy / max(endClip.w, kLayerNearW) * halfViewport;
    var direction = endScreen - startScreen;
    let length2 = dot(direction, direction);
    if (length2 > 1.0e-8) {
        direction = direction * inverseSqrt(length2);
    } else {
        direction = vec2f(1.0, 0.0);
    }
    let normal = vec2f(-direction.y, direction.x);

    let corner = kLayerLineCorners[vertexID % 10u];
    let atEnd = corner.x > 0.5;
    let rounding = (segment.color >> 24u) & 0xFFu;
    let isRound = (rounding & select(1u, 2u, atEnd)) != 0u;
    // A round end reaches past the segment's end by the line's half
    // width, and two segments that meet with round ends overlap in a disc,
    // which is their join. A flat end stops at the segment's end: its
    // corners fall onto the end's edge and its triangles are empty.
    let outwardPx = select(0.0, corner.y, isRound);
    let halfWidthPx = segment.widthPoints * draw.pixelsPerPoint * 0.5;
    let offsetPx = (normal * corner.z + direction * select(-outwardPx, outwardPx, atEnd)) * halfWidthPx;
    var at = start;
    var position = startClip;
    if (atEnd) {
        at = end;
        position = endClip;
    }
    position = vec4f(position.xy + offsetPx / halfViewport * position.w, position.zw);

    var out: LayerLineOut;
    out.position = position;
    out.clipDistance = select(at.clipDistance, -1.0, startClip.w < kLayerNearW && endClip.w < kLayerNearW);
    out.worldPosition = at.worldPosition;
    out.sphereNormal = at.sphereNormal;
    out.color = vec4f(unpack4x8unorm(segment.color).rgb, 1.0);
    return out;
}

/// A line's fragment is whole: the shape is its geometry, with no edge to
/// soften, and the pass does not blend (`LayerPipeline`). Only where
/// Metal's hardware clip would cut it (the clip distance) is it discarded.
@fragment
fn layerLineFragment(in: LayerLineOut) -> @location(0) vec4f {
    if (in.clipDistance < 0.0) {
        discard;
    }
    return layerShade(in.color, in.worldPosition, in.sphereNormal);
}

// MARK: - Points

struct LayerPointOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    @location(1) sphereNormal: vec3f,
    @location(2) @interpolate(flat) color: vec4f,
    @location(3) @interpolate(flat) strokeColor: vec4f,
    /// The fragment's offset from the centre, in pixels.
    @location(4) offsetPx: vec2f,
    @location(5) @interpolate(flat) radiusPx: f32,
    @location(6) @interpolate(flat) strokeWidthPx: f32,
    @location(7) clipDistance: f32,
}

@vertex
fn layerPointVertex(@builtin(vertex_index) vertexID: u32, @builtin(instance_index) instanceID: u32) -> LayerPointOut {
    var corners = array<vec2f, 6>(vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(-1.0, 1.0),
                                  vec2f(-1.0, 1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0));
    let instance = pointInstances[instanceID];
    let centre = layerProject(instance.position);
    let radiusPx = instance.radiusPoints * draw.pixelsPerPoint;
    let strokeWidthPx = instance.strokeWidthPoints * draw.pixelsPerPoint;
    let extentPx = radiusPx + strokeWidthPx + 1.0;
    let corner = corners[vertexID % 6u];

    var out: LayerPointOut;
    out.position = centre.position;
    out.position = vec4f(out.position.xy + corner * extentPx / (draw.viewportSizePx * 0.5) * out.position.w, out.position.zw);
    out.clipDistance = select(centre.clipDistance, -1.0, centre.position.w < kLayerNearW);
    out.worldPosition = centre.worldPosition;
    out.sphereNormal = centre.sphereNormal;
    out.color = unpack4x8unorm(instance.color);
    out.strokeColor = unpack4x8unorm(instance.strokeColor);
    out.offsetPx = corner * extentPx;
    out.radiusPx = radiusPx;
    out.strokeWidthPx = strokeWidthPx;
    return out;
}

@fragment
fn layerPointFragment(in: LayerPointOut) -> @location(0) vec4f {
    if (in.clipDistance < 0.0) {
        discard;
    }
    let distance = length(in.offsetPx);
    // The disc, then the ring outside it, each with a pixel of antialiasing
    // at its edge.
    let inside = saturate(in.radiusPx + 0.5 - distance);
    // Outside the ring the coverage is zero, and so is the alpha: the pass
    // blends and writes neither depth nor stencil (`LayerPipeline`), so a
    // corner of the quad changes nothing without a discard.
    let covered = saturate(in.radiusPx + in.strokeWidthPx + 0.5 - distance);
    var color = in.color;
    if (in.strokeWidthPx > 0.0) {
        color = mix(in.strokeColor, in.color, inside);
    }
    color.a *= covered;
    return layerShade(color, in.worldPosition, in.sphereNormal);
}
