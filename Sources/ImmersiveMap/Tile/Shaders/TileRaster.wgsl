// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: TileRaster.metal fnv1a64=552590f7af7c7d38
// include: TileShading.wgsl
// include: ../Relief/Shaders/GroundRelief.wgsl
// include: ../../Globe/Shaders/GlobeTileProjection.wgsl
// include: ../../Globe/Shaders/GlobeTransitionProjection.wgsl
// include: ../../Globe/Shaders/GlobeUnroll.wgsl
// include: ../../Globe/Shaders/GlobeLight.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl

// The raster tiles (RasterTileRenderSubsystem): a tile's ground baked into
// a texture, and the texture drawn on a grid in the tile's place, on the
// plane, on the relief, on the resting sphere and through the unroll. The
// grid also draws the relief as a shadow caster and the placement
// prepass's marks (PlacementStencilPipeline), with the prepass's depth
// reset. TileRaster.metal explains the depths.
//
// The grid is a storage buffer read by the vertex index, not a vertex
// buffer. The draw stages share one interpolant struct, the unroll's cut
// included: the plane and the resting sphere write 1, and the fragment
// stages discard where it is negative.

/// The raster tile on the ground relief: the grid rises by the terrain, and
/// the fragment samples the shadow cascades at the raised point.
@id(0) override kTileRasterRelief: bool;

const kTileRasterExtent = 4096.0;
/// The flat rank depth, one value with Tile.wgsl: half a step behind the
/// ground band's first step.
const kTileRasterFlatLayerDepthStep = 3.2e-6;
const kTileRasterBehindFillsShare = 0.5;
const kTileRasterFlatRealDepthScale = 1.0 - 1536.0 * kTileRasterFlatLayerDepthStep;
const kTileRasterReliefBandScale = 0.25;
const kTileRasterReliefGroundBehind = 2.0 * kTileRasterFlatLayerDepthStep;
/// Mask pixels per drawable pixel, one value with Tile.wgsl.
const kTileRasterGroundShadowMaskScale = 0.4;
/// The sphere's first rank, one value with TileSphere.wgsl.
const kTileRasterSphereLayerDepthStep = 3.2e-6;

/// The texture coordinate of a tile-local position: x east, v from the
/// tile's north edge.
fn tileRasterTextureUv(localPosition: vec2f) -> vec2f {
    return vec2f(localPosition.x, kTileRasterExtent - localPosition.y) / kTileRasterExtent;
}

// MARK: - Bake

struct TileRasterBakeVertexOut {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
}

@group(0) @binding(2) var<storage, read> bakeStyles: array<Style>;
@group(0) @binding(4) var<storage, read> bakeStyleZoomFades: array<vec2f>;
@group(0) @binding(11) var<uniform> bakeFade: OverviewFadeUniform;

@vertex
fn tileRasterBakeVertexShader(vertexIn: VertexIn) -> TileRasterBakeVertexOut {
    var out: TileRasterBakeVertexOut;
    // The tile's extent fills the texture: local y up is clip y up.
    let clip = vertexIn.position / kTileRasterExtent * 2.0 - 1.0;
    out.position = vec4f(clip, 0.0, 1.0);
    out.color = bakeStyles[vertexIn.styleIndex].color;
    out.color.a *= tileStyleFade(bakeStyleZoomFades[vertexIn.styleIndex], bakeFade);
    return out;
}

@fragment
fn tileRasterBakeFragmentShader(in: TileRasterBakeVertexOut) -> @location(0) vec4f {
    return in.color;
}

// MARK: - Draw

/// Mirror of RasterTileSamplingUniform (fragment binding 1): the bias added
/// to the mip level the GPU picks.
struct TileRasterSampling {
    mipLevelBias: f32,
}

/// Mirror of GlobeSurfaceTileUniform.swift (vertex binding 9).
struct TileRasterSurfaceTile {
    uvOrigin: vec2f,
    uvScale: f32,
    referenceWorldX: f32,
}

struct TileRasterVertexOut {
    @builtin(position) position: vec4f,
    @location(0) uv: vec2f,
    /// The plane's point, for the ground fog. Unused on the sphere.
    @location(1) worldPosition: vec3f,
    /// The sphere's normal in world space. Unused on the plane.
    @location(2) sphereNormal: vec3f,
    /// Metal's clip distance, the unroll's cut: 1 elsewhere.
    @location(3) clipDistance: f32,
}

@group(0) @binding(0) var<storage, read> grid: array<vec2f>;
@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(3) var<uniform> modelMatrix: mat4x4f;
@group(0) @binding(8) var<uniform> globe: Globe;
@group(0) @binding(9) var<uniform> vertexRelief: GroundReliefUniform;
@group(0) @binding(10) var<uniform> globeFrame: GlobeFrameConstants;
@group(0) @binding(16) var reliefHeightsVertex: texture_2d<f32>;
@group(0) @binding(49) var vertexLinearSampler: sampler;

@group(1) @binding(1) var<uniform> sampling: TileRasterSampling;
@group(1) @binding(3) var<uniform> shadow: Shadow;
@group(1) @binding(9) var<uniform> relief: GroundReliefUniform;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;
@group(1) @binding(16) var raster: texture_2d<f32>;
@group(1) @binding(17) var groundShadowMask: texture_2d<f32>;
@group(1) @binding(18) var shadowMap: texture_depth_2d_array;
@group(1) @binding(19) var reliefHeights: texture_2d<f32>;
@group(1) @binding(20) var reliefOcclusion: texture_2d<f32>;
@group(1) @binding(32) var rasterSampler: sampler;
@group(1) @binding(48) var shadowCompareSampler: sampler_comparison;
@group(1) @binding(49) var linearSampler: sampler;

/// The tile's colour, opaque. Sampled with the bias, which takes
/// derivatives: called first, in uniform control flow.
fn tileRasterColor(uv: vec2f) -> vec4f {
    let color = textureSampleBias(raster, rasterSampler, uv, sampling.mipLevelBias);
    return vec4f(color.rgb, 1.0);
}

@vertex
fn tileRasterFlatVertexShader(@builtin(vertex_index) vertexID: u32) -> TileRasterVertexOut {
    let localPosition = grid[vertexID];
    var out: TileRasterVertexOut;
    var worldPosition = modelMatrix * vec4f(localPosition, 0.0, 1.0);
    if (kTileRasterRelief) {
        worldPosition.z += groundReliefLift(localPosition, reliefHeightsVertex, vertexLinearSampler, vertexRelief);
    }
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    // The plane has no sphere: the light reads nothing there.
    out.sphereNormal = vec3f(0.0, 0.0, 1.0);
    let step = kTileRasterFlatLayerDepthStep * kTileRasterBehindFillsShare;
    if (kTileRasterRelief) {
        out.position.z *= 1.0 + kTileRasterReliefGroundBehind - step * kTileRasterReliefBandScale;
    } else {
        out.position.z *= (1.0 - step) / kTileRasterFlatRealDepthScale;
    }
    out.uv = tileRasterTextureUv(localPosition);
    out.clipDistance = 1.0;
    return out;
}

@fragment
fn tileRasterFlatFragmentShader(in: TileRasterVertexOut) -> @location(0) vec4f {
    var color = tileRasterColor(in.uv);
    if (in.clipDistance < 0.0) {
        discard;
    }
    // The slopes shaded as the vector ground's fills shade them.
    if (kTileRasterRelief) {
        let shadingUV = relief.shading.xy + saturate(in.uv) * relief.shading.z;
        color = vec4f(groundReliefHillshade(color.rgb, shadingUV, in.worldPosition, reliefHeights, linearSampler, relief),
                      color.a);
        color = vec4f(groundReliefOcclude(color.rgb, shadingUV, reliefOcclusion, linearSampler, relief), color.a);
    }
    // The ground shadow mask on the plane, the cascades at the raised point
    // on the relief. Metal samples the mask in pixel coordinates, WGSL in
    // normalized ones.
    var shadowFactor = 1.0;
    if (kTileRasterRelief) {
        shadowFactor = sampleShadowFactor(shadow, shadowMap, shadowCompareSampler, in.worldPosition, vec3f(0.0));
    } else if (shadow.strength > 0.0) {
        let maskUV = in.position.xy * kTileRasterGroundShadowMaskScale / vec2f(textureDimensions(groundShadowMask));
        shadowFactor = textureSampleLevel(groundShadowMask, linearSampler, maskUV, 0.0).r;
    }
    color = vec4f(color.rgb * shadowColorMultiplier(shadow, shadowFactor), color.a);
    return vec4f(applyGroundFog(color.rgb, in.worldPosition, groundFog), color.a);
}

// MARK: - The relief's shadow

@group(0) @binding(1) var<uniform> casters: ShadowCasterMatrices;

/// The ground relief as a shadow caster: the grid over a placement's
/// square, raised by the terrain, seen from the light. Depth only.
@vertex
fn tileRasterReliefShadowVertexShader(@builtin(vertex_index) vertexID: u32) -> @builtin(position) vec4f {
    let localPosition = grid[vertexID];
    var worldPosition = modelMatrix * vec4f(localPosition, 0.0, 1.0);
    worldPosition.z += groundReliefLift(localPosition, reliefHeightsVertex, vertexLinearSampler, vertexRelief);
    return casterClipPosition(casters.lightProjectionView * worldPosition);
}

// MARK: - The placement prepass's depth reset

/// One triangle over the whole screen at the far plane, counter-clockwise.
/// Depth only.
@vertex
fn placementDepthResetVertexShader(@builtin(vertex_index) vertexID: u32) -> @builtin(position) vec4f {
    var positions = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    return vec4f(positions[vertexID], 1.0, 1.0);
}

// MARK: - The sphere

@group(0) @binding(9) var<uniform> surfaceTile: TileRasterSurfaceTile;

fn tileRasterWorldUv(localPosition: vec2f) -> vec2f {
    return surfaceTile.uvOrigin + tileRasterTextureUv(localPosition) * surfaceTile.uvScale;
}

@vertex
fn tileRasterSpherePureVertexShader(@builtin(vertex_index) vertexID: u32) -> TileRasterVertexOut {
    let localPosition = grid[vertexID];
    let unitDirection = globeWorldUVUnitDirection(tileRasterWorldUv(localPosition));
    var out: TileRasterVertexOut;
    out.position = globeFrame.sphereClip * vec4f(unitDirection, 1.0);
    out.position.z = (1.0 - kTileRasterSphereLayerDepthStep) * out.position.w;
    out.uv = tileRasterTextureUv(localPosition);
    out.worldPosition = vec3f(0.0);
    out.sphereNormal = (globeFrame.sphereWorld * vec4f(unitDirection, 0.0)).xyz;
    out.clipDistance = 1.0;
    return out;
}

@vertex
fn tileRasterSphereMorphVertexShader(@builtin(vertex_index) vertexID: u32) -> TileRasterVertexOut {
    let localPosition = grid[vertexID];
    let worldUv = tileRasterWorldUv(localPosition);
    let unitDirection = globeWorldUVUnitDirection(worldUv);
    let sphereWorldPosition = (globeFrame.sphereWorld * vec4f(unitDirection, 1.0)).xyz;
    let mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    let flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                             globeFrame.mapSize, globeFrame.panMercatorY,
                                                             surfaceTile.referenceWorldX);
    let worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                 globe.transition, globe.radius);
    var out: TileRasterVertexOut;
    out.position = camera.matrix * vec4f(worldPosition, 1.0);
    out.position.z = (1.0 - kTileRasterSphereLayerDepthStep) * out.position.w;
    out.clipDistance = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                               globe.transition, globe.radius);
    out.uv = tileRasterTextureUv(localPosition);
    out.worldPosition = vec3f(0.0);
    out.sphereNormal = (globeFrame.sphereWorld * vec4f(unitDirection, 0.0)).xyz;
    return out;
}

@group(1) @binding(9) var<uniform> globeLight: GlobeLight;

@fragment
fn tileRasterSphereFragmentShader(in: TileRasterVertexOut) -> @location(0) vec4f {
    let color = tileRasterColor(in.uv);
    if (in.clipDistance < 0.0) {
        discard;
    }
    return vec4f(globeLitColor(color.rgb, in.sphereNormal, globeLight), color.a);
}
