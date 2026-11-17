// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: Layers.metal fnv1a64=c5704a9579f6601e
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl
// include: ../../Globe/Shaders/GlobeUnroll.wgsl
// include: ../../Globe/Shaders/GlobeTransitionProjection.wgsl
// include: ../../Globe/Shaders/GlobeTileProjection.wgsl
// include: ../../Globe/Shaders/GlobeLight.wgsl

// The layers of the app's data (ImmersiveMapLayer): zones, lines and points
// lying on the ground, each vertex projected the ground's own way on the
// surface the frame draws. A zone is its triangles, a line a quad per
// segment widened on screen, a point a disc with a ring. Layers.metal
// explains them.
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

/// Mirrors LayerLineVertex in LayerMeshBuilder.swift.
struct LayerLineVertex {
    start: vec2f,
    end: vec2f,
    corner: vec2f,
    widthPoints: f32,
    color: u32,
}

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
@group(0) @binding(0) var<storage, read> lineVertices: array<LayerLineVertex>;
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
    /// The signed distance from the centreline across the quad, in pixels.
    @location(4) edgePx: f32,
    /// The line's half width in pixels.
    @location(5) @interpolate(flat) halfWidthPx: f32,
}

@vertex
fn layerLineVertex(@builtin(vertex_index) vertexID: u32) -> LayerLineOut {
    let vertexIn = lineVertices[vertexID];
    let start = layerProject(vertexIn.start);
    let end = layerProject(vertexIn.end);
    // An end behind the camera is pulled to just before it along the
    // segment, so the quad's direction on screen stays the segment's.
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

    let halfWidthPx = vertexIn.widthPoints * draw.pixelsPerPoint * 0.5;
    // A pixel of margin for the edge's antialiasing.
    let extentPx = halfWidthPx + 1.0;
    let atEnd = vertexIn.corner.x > 0.5;
    var at = start;
    var position = startClip;
    if (atEnd) {
        at = end;
        position = endClip;
    }
    position = vec4f(position.xy + normal * (vertexIn.corner.y * extentPx) / halfViewport * position.w, position.zw);

    var out: LayerLineOut;
    out.position = position;
    out.clipDistance = select(at.clipDistance, -1.0, startClip.w < kLayerNearW && endClip.w < kLayerNearW);
    out.worldPosition = at.worldPosition;
    out.sphereNormal = at.sphereNormal;
    out.color = unpack4x8unorm(vertexIn.color);
    out.edgePx = vertexIn.corner.y * extentPx;
    out.halfWidthPx = halfWidthPx;
    return out;
}

@fragment
fn layerLineFragment(in: LayerLineOut) -> @location(0) vec4f {
    if (in.clipDistance < 0.0) {
        discard;
    }
    var color = in.color;
    color.a *= saturate(in.halfWidthPx + 0.5 - abs(in.edgePx));
    return layerShade(color, in.worldPosition, in.sphereNormal);
}

// MARK: - Points and joins

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
    let covered = saturate(in.radiusPx + in.strokeWidthPx + 0.5 - distance);
    if (covered <= 0.0) {
        discard;
    }
    var color = in.color;
    if (in.strokeWidthPx > 0.0) {
        color = mix(in.strokeColor, in.color, inside);
    }
    color.a *= covered;
    return layerShade(color, in.worldPosition, in.sphereNormal);
}
