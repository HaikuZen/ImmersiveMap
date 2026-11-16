// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: TileSphere.metal fnv1a64=8af8afe7698090c7
// include: TileShading.wgsl
// include: ../../Globe/Shaders/GlobeTileProjection.wgsl
// include: ../../Globe/Shaders/GlobeTransitionProjection.wgsl
// include: ../../Globe/Shaders/GlobeUnroll.wgsl
// include: ../../Globe/Shaders/GlobeLight.wgsl

// The tile geometry of the globe, drawn straight onto the sphere: the same
// vertices, styles, line coverage and fades as the flat ground. Two vertex
// stages, the resting sphere and the unfurl, and one fragment stage under
// the globe's light. TileSphere.metal explains the rank-depth band and the
// ribbons' phases.
//
// Every variant carries every interpolant, as an override removes none.
// The pure sphere has no clip distance in Metal: it writes 1 here, so both
// vertex stages feed the one fragment stage, which discards where the
// unroll's cut is negative.

/// The fragment applies the horizon fog. Unused by the stages, as in Metal.
@id(0) override kTileSphereFog: bool;
/// The pass carries the line fields: the morph's combined pass and the
/// ribbons class.
@id(1) override kTileSphereLineFields: bool;
/// Which part of a ribbon the pass draws: 0 the whole ribbon, 1 the core,
/// 2 the feather (TilePipeline.SphereRibbonPhase).
@id(2) override kTileSphereRibbonPhase: i32;

const kTileSphereRibbonPhaseWhole = 0;
const kTileSphereRibbonPhaseCore = 1;
const kTileSphereRibbonCoreCoverage = 0.5;
const kTileSphereExtent = 4096.0;
/// The ground's rank depth: a band at the far plane ordered class first,
/// style rank second. Mirrored by GlobeSurfaceDepthRank.
const kTileSphereLayerDepthStep = 3.2e-6;
const kTileSphereRibbonDepthBand = 257.0 * kTileSphereLayerDepthStep;

/// Mirror of GlobeSurfaceTileUniform.swift (vertex binding 9).
struct GlobeSurfaceTile {
    uvOrigin: vec2f,
    uvScale: f32,
    referenceWorldX: f32,
}

/// Mirror of TileSphereHandoverUniform (vertex binding 12, fragment 8).
struct SphereHandoverUniform {
    handover: f32,
}

struct SphereVertexOut {
    @builtin(position) position: vec4f,
    @location(0) sphereNormal: vec3f,
    @location(1) worldPos: vec3f,
    @location(2) color: vec4f,
    @location(3) @interpolate(flat) styleIndex: u32,
    @location(4) lineDistance: f32,
    @location(5) lineParameterRaw: f32,
    /// Metal's clip distance, the unroll's cut: 1 on the resting sphere.
    @location(6) clipDistance: f32,
}

@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(2) var<storage, read> vertexStyles: array<Style>;
@group(0) @binding(4) var<storage, read> vertexStyleZoomFades: array<vec2f>;
@group(0) @binding(5) var<storage, read> vertexLineStyles: array<LineStyle>;
@group(0) @binding(8) var<uniform> globe: Globe;
@group(0) @binding(9) var<uniform> surfaceTile: GlobeSurfaceTile;
@group(0) @binding(10) var<uniform> globeFrame: GlobeFrameConstants;
@group(0) @binding(11) var<uniform> vertexOverviewFade: OverviewFadeUniform;
@group(0) @binding(12) var<uniform> vertexHandover: SphereHandoverUniform;

@group(1) @binding(0) var<uniform> overviewFade: OverviewFadeUniform;
@group(1) @binding(4) var<uniform> lineDash: LineDashUniform;
@group(1) @binding(5) var<storage, read> styles: array<Style>;
@group(1) @binding(6) var<storage, read> styleZoomFades: array<vec2f>;
@group(1) @binding(7) var<storage, read> lineStyles: array<LineStyle>;
@group(1) @binding(8) var<uniform> handover: SphereHandoverUniform;
@group(1) @binding(9) var<uniform> globeLight: GlobeLight;

/// The tile-local vertex position as a world uv (x east in turns, y the
/// Mercator row from the north edge).
fn tileSphereWorldUv(localPosition: vec2f) -> vec2f {
    let localUv = vec2f(localPosition.x, kTileSphereExtent - localPosition.y) / kTileSphereExtent;
    return surfaceTile.uvOrigin + localUv * surfaceTile.uvScale;
}

/// The rank band's z, class then style, as a scale of w.
fn tileSphereLayerNdcZ(styleIndex: u32) -> f32 {
    var layerNdcZ = 1.0 - (f32(styleIndex) + 1.0) * kTileSphereLayerDepthStep;
    if (kTileSphereLineFields) {
        layerNdcZ -= kTileSphereRibbonDepthBand;
    }
    return layerNdcZ;
}

/// The class's outputs: the fills resolve their colour, the globe's look
/// handed over to the fill's own with the air, the ribbons export the
/// style index and the raw line fields.
fn tileSphereWriteStyle(out: ptr<function, SphereVertexOut>, vertexIn: VertexIn) {
    (*out).color = vec4f(0.0);
    (*out).styleIndex = 0u;
    (*out).lineDistance = 0.0;
    (*out).lineParameterRaw = 0.0;
    if (kTileSphereLineFields) {
        (*out).styleIndex = vertexIn.styleIndex;
        (*out).lineDistance = f32(vertexIn.lineDistance) / 127.0;
        (*out).lineParameterRaw = f32(vertexIn.lineParameter);
    } else {
        let style = tileVertexStyle(vertexStyles[vertexIn.styleIndex], vertexStyleZoomFades[vertexIn.styleIndex]);
        let lineStyle = vertexLineStyles[vertexIn.styleIndex];
        var color = style.color;
        color = vec4f(mix(tileLineSphereColor(lineStyle), color.rgb, vertexHandover.handover), color.a);
        color.a *= tileStyleFade(style.zoomFade, vertexOverviewFade);
        (*out).color = color;
    }
}

/// The resting sphere: one composed matrix takes the unit earth direction
/// to clip space, and back-face culling removes the far side.
@vertex
fn tileSpherePureVertexShader(vertexIn: VertexIn) -> SphereVertexOut {
    let unitDirection = globeWorldUVUnitDirection(tileSphereWorldUv(vertexIn.position));

    var out: SphereVertexOut;
    out.position = globeFrame.sphereClip * vec4f(unitDirection, 1.0);
    out.sphereNormal = (globeFrame.sphereWorld * vec4f(unitDirection, 0.0)).xyz;
    out.position.z = tileSphereLayerNdcZ(vertexIn.styleIndex) * out.position.w;
    out.worldPos = vec3f(0.0);
    out.clipDistance = 1.0;
    tileSphereWriteStyle(&out, vertexIn);
    return out;
}

/// The unfurl: the sphere-to-plane unroll, cut where it tears.
@vertex
fn tileSphereMorphVertexShader(vertexIn: VertexIn) -> SphereVertexOut {
    let worldUv = tileSphereWorldUv(vertexIn.position);
    let unitDirection = globeWorldUVUnitDirection(worldUv);
    let sphereWorldPosition = (globeFrame.sphereWorld * vec4f(unitDirection, 1.0)).xyz;
    // The flat morph target is the Mercator plane, the vertex's world uv,
    // with the row turned north-positive in -1...1.
    let mercatorY = clamp(1.0 - 2.0 * worldUv.y, -1.0, 1.0);
    let flatWorldPosition = globeTransitionFlatWorldPosition(worldUv.x, mercatorY, globe,
                                                             globeFrame.mapSize, globeFrame.panMercatorY,
                                                             surfaceTile.referenceWorldX);
    let worldPosition = globeUnrollWorldPosition(sphereWorldPosition, flatWorldPosition,
                                                 globe.transition, globe.radius);

    var out: SphereVertexOut;
    out.position = camera.matrix * vec4f(worldPosition, 1.0);
    out.sphereNormal = (globeFrame.sphereWorld * vec4f(unitDirection, 0.0)).xyz;
    out.position.z = tileSphereLayerNdcZ(vertexIn.styleIndex) * out.position.w;
    out.clipDistance = globeUnrollCutClearance(sphereWorldPosition, flatWorldPosition,
                                               globe.transition, globe.radius);
    out.worldPos = vec3f(0.0);
    if (kTileSphereFog) {
        out.worldPos = worldPosition;
    }
    tileSphereWriteStyle(&out, vertexIn);
    return out;
}

/// No shadows and no fog on the globe: the colour comes from the style and
/// the coverage, under the globe's light.
@fragment
fn tileSphereFragmentShader(in: SphereVertexOut) -> @location(0) vec4f {
    if (in.clipDistance < 0.0) {
        discard;
    }
    var color: vec4f;
    if (kTileSphereLineFields) {
        let lineStyle = lineStyles[in.styleIndex];
        if (kTileSphereRibbonPhase != kTileSphereRibbonPhaseWhole) {
            // The phase's share of the ribbon: the coverage decides.
            let coverage = tileLineFragmentCoverage(lineStyle, in.lineDistance, in.lineParameterRaw,
                                                    overviewFade, lineDash, 0.0);
            let isCore = coverage >= kTileSphereRibbonCoreCoverage;
            if (isCore != (kTileSphereRibbonPhase == kTileSphereRibbonPhaseCore)) {
                discard;
            }
        }
        // No deferred ribbons on the sphere: every rim is baked.
        color = tileLineFragmentColor(styles[in.styleIndex], styleZoomFades[in.styleIndex], lineStyle,
                                      in.lineDistance, in.lineParameterRaw,
                                      overviewFade, lineDash, 0.0);
        // The globe's look of the stroke, handed over to the plane's with
        // the air, unless it switches at a zoom of its own.
        if (!tileLineSwitchesLookByZoom(lineStyle)) {
            color = vec4f(mix(tileLineSphereColor(lineStyle), color.rgb, handover.handover),
                          color.a * mix(lineStyle.sphereAlpha, 1.0, handover.handover));
        }
    } else {
        color = in.color;
    }
    return vec4f(globeLitColor(color.rgb, in.sphereNormal, globeLight), color.a);
}
