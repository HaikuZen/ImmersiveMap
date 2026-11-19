// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: Tile.metal fnv1a64=edbc80cbd412ede8
// include: TileShading.wgsl
// include: ../Relief/Shaders/GroundRelief.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl

// The flat ground (TilePipeline, FlatMapSurfaceDrawer): the fills, the line
// ribbons, the road ribbons and the bridge overlay of a tile, laid on the
// plane or raised by the relief, in the rank-depth band. Tile.metal
// explains the depth, the deferred ribbons and the roads.
//
// Metal leaves an interpolant out of a variant by a function constant. An
// override removes nothing in WGSL: every variant carries every
// interpolant, and the ones a variant does not use are written as zero.
// Metal's hardware clip distance is an interpolant here, and the fragment
// stages discard where it is negative.

/// The flat world pass reads the per-pixel ground shadow mask, the relief's
/// variants sample the cascades at their raised points.
@id(0) override kGroundShadowMaskEnabled: bool;
/// The pass carries the analytic line fields: the ribbons, the roads and
/// the bridge overlay.
@id(1) override kTileLineFields: bool;
/// The road ribbons of a tile whose ribbons are deferred.
@id(4) override kTileRoadRibbons: bool;
/// The road ribbons that are not opaque this frame.
@id(5) override kTileRoadBlended: bool;
/// The flattened ground raised by its terrain.
@id(6) override kTileGroundRelief: bool;

override kTileFillFields = !kTileLineFields;
override kTileCoverageFields = kTileLineFields && !kTileRoadRibbons;
override kTileStyleIndexField = kTileLineFields && (!kTileRoadRibbons || kTileRoadBlended);
override kTileGroundReliefShade = kTileGroundRelief && kTileFillFields;

/// Mask pixels per drawable pixel. Mirrors
/// GroundShadowMaskPipeline.resolutionScale.
const kGroundShadowMaskScale = 0.4;
/// The flat rank-depth step, one value with the sphere's. Mirrored by
/// GlobeSurfaceDepthRank.
const kFlatTileLayerDepthStep = 3.2e-6;
/// The camera's near plane in view units (RenderCamera.nearPlane).
const kFlatCameraNearPlane = 0.01;
/// The scale the camera's projection applies to the z of everything real
/// (RenderCamera.realDepthScale).
const kFlatRealDepthScale = 1.0 - 1536.0 * kFlatTileLayerDepthStep;
/// The relief's band, shrunk and set behind the real geometry.
const kReliefBandScale = 0.25;
const kReliefGroundBehind = 2.0 * kFlatTileLayerDepthStep;
/// The farthest a deferred ribbon's vertex moves, in tile units.
const kTileDeferredRibbonMaximumUnits = 1024.0;
/// The narrowest a road ribbon is extruded, in pixels from the centreline.
const kTileRoadMinimumHalfWidthPx = 0.5;
/// The style ranks of one road band (RoadRankDepth.ranksPerBand).
const kTileRoadBandRanks = 12.0;

/// Mirror of FlatDepthBand (vertex binding 7).
struct FlatDepthBand {
    offset: f32,
    rankStep: f32,
}

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) worldPos: vec3f,
    @location(1) color: vec4f,
    @location(2) @interpolate(flat) styleIndex: u32,
    @location(3) lineDistance: f32,
    @location(4) lineParameterRaw: f32,
    @location(5) @interpolate(flat) deferredEdgePx: f32,
    @location(6) widthAxis: vec2f,
    @location(7) reliefUV: vec2f,
    /// Metal's clip distance: negative cuts a road invisible this frame.
    @location(8) clipDistance: f32,
}

@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(2) var<storage, read> vertexStyles: array<Style>;
@group(0) @binding(3) var<uniform> modelMatrix: mat4x4f;
@group(0) @binding(4) var<storage, read> vertexStyleZoomFades: array<vec2f>;
@group(0) @binding(5) var<storage, read> vertexLineStyles: array<LineStyle>;
@group(0) @binding(7) var<uniform> depthBand: FlatDepthBand;
@group(0) @binding(8) var<uniform> vertexOverviewFade: OverviewFadeUniform;
@group(0) @binding(9) var<uniform> vertexRelief: GroundReliefUniform;
@group(0) @binding(16) var reliefHeightsVertex: texture_2d<f32>;
@group(0) @binding(49) var vertexLinearSampler: sampler;

@group(1) @binding(0) var<uniform> overviewFade: OverviewFadeUniform;
@group(1) @binding(3) var<uniform> shadow: Shadow;
@group(1) @binding(4) var<uniform> lineDash: LineDashUniform;
@group(1) @binding(5) var<storage, read> styles: array<Style>;
@group(1) @binding(6) var<storage, read> styleZoomFades: array<vec2f>;
@group(1) @binding(7) var<storage, read> lineStyles: array<LineStyle>;
@group(1) @binding(9) var<uniform> relief: GroundReliefUniform;
@group(1) @binding(11) var<uniform> alphaScale: f32;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;
@group(1) @binding(16) var shadowMap: texture_depth_2d_array;
@group(1) @binding(17) var groundShadowMask: texture_2d<f32>;
@group(1) @binding(19) var reliefHeights: texture_2d<f32>;
@group(1) @binding(20) var reliefOcclusion: texture_2d<f32>;
@group(1) @binding(48) var shadowCompareSampler: sampler_comparison;
@group(1) @binding(49) var linearSampler: sampler;

@vertex
fn tileVertexShader(vertexIn: VertexIn) -> VertexOut {
    var localPosition = vertexIn.position;
    var deferredEdgePx = 0.0;
    var widthAxis = vec2f(0.0);
    if (kTileLineFields) {
        // A deferred ribbon: the vertex is a point of the centreline and
        // moves out along its direction by the style's width on screen
        // (Tile.metal).
        var normal = vertexIn.normal;
        if (dot(normal, normal) > 0.25) {
            normal = normalize(normal);
            widthAxis = normal;
            let lineStyle = vertexLineStyles[vertexIn.styleIndex];
            let clipCentre = camera.matrix * (modelMatrix * vec4f(localPosition, 0.0, 1.0));
            let clipAlong = camera.matrix * (modelMatrix * vec4f(normal, 0.0, 0.0));
            let w0 = max(clipCentre.w, kFlatCameraNearPlane);
            let w1 = max(clipCentre.w + clipAlong.w, kFlatCameraNearPlane);
            let screenSpan = ((clipCentre.xy + clipAlong.xy) / w1 - clipCentre.xy / w0)
                * vertexOverviewFade.viewportSizePx * 0.5;
            let pixelsPerUnit = max(length(screenSpan), 1e-4);
            deferredEdgePx = tileLineEdgePixels(lineStyle, pixelsPerUnit,
                                                vertexOverviewFade.pixelsPerPoint, vertexOverviewFade.cameraZoom);
            var isotropicPixelsPerUnit = pixelsPerUnit;
            if (vertexOverviewFade.pointWidthReferenceDepth > 0.0
                && vertexOverviewFade.pointWidthCentrePixelsPerWorldUnit > 0.0) {
                isotropicPixelsPerUnit = max(vertexOverviewFade.pointWidthCentrePixelsPerWorldUnit
                                                 * vertexOverviewFade.pointWidthReferenceDepth / w0
                                                 * max(length(modelMatrix[0].xyz), 1e-9),
                                             1e-4);
            }
            var units: f32;
            if (lineStyle.widthPoints > 0.0
                && vertexOverviewFade.pointWidthReferenceDepth > 0.0
                && vertexOverviewFade.pointWidthCentrePixelsPerWorldUnit > 0.0) {
                // A point-locked width lies on the ground: one ground
                // half-width per style, in tile units through the model's
                // scale.
                let unitsPerWorld = 1.0 / max(length(modelMatrix[0].xyz), 1e-9);
                units = deferredEdgePx / vertexOverviewFade.pointWidthCentrePixelsPerWorldUnit * unitsPerWorld;
            } else {
                // A width on screen: the rim moves by the width at this
                // vertex's own scale.
                var rimEdgePx = deferredEdgePx;
                if (lineStyle.widthPoints > 0.0) {
                    rimEdgePx *= tilePointWidthPerspectiveScale(vertexOverviewFade, w0, normal, clipCentre.xy / w0);
                }
                units = rimEdgePx / pixelsPerUnit;
            }
            if (kTileRoadRibbons) {
                // A road: the rim is the style's edge itself, never under
                // half a pixel from the centreline.
                units = max(units, kTileRoadMinimumHalfWidthPx / isotropicPixelsPerUnit);
            } else {
                units += kTileDeferredRibbonFeatherPx / isotropicPixelsPerUnit;
            }
            units = min(units, kTileDeferredRibbonMaximumUnits);
            localPosition += normal * units;
        }
    }
    var worldPosition = modelMatrix * vec4f(localPosition, 0.0, 1.0);
    if (kTileGroundRelief) {
        worldPosition.z += groundReliefLift(localPosition, reliefHeightsVertex, vertexLinearSampler, vertexRelief);
    }

    var out: VertexOut;
    out.position = camera.matrix * worldPosition;
    // The layer's rank as a scale of the plane's z (Tile.metal).
    var styleRank = f32(vertexIn.styleIndex);
    if (kTileRoadRibbons) {
        styleRank = min(styleRank, kTileRoadBandRanks - 1.0);
    }
    let layerDepthScale = 1.0 - depthBand.offset
        - styleRank * depthBand.rankStep - kFlatTileLayerDepthStep;
    if (kTileGroundRelief) {
        out.position.z *= 1.0 + kReliefGroundBehind - (1.0 - layerDepthScale) * kReliefBandScale;
    } else {
        out.position.z *= layerDepthScale / kFlatRealDepthScale;
    }
    out.worldPos = worldPosition.xyz;
    out.color = vec4f(0.0);
    out.styleIndex = 0u;
    out.lineDistance = 0.0;
    out.lineParameterRaw = 0.0;
    out.deferredEdgePx = 0.0;
    out.widthAxis = vec2f(0.0);
    out.reliefUV = vec2f(0.0);
    if (kTileGroundReliefShade) {
        out.reliefUV = groundReliefShadingUV(localPosition, vertexRelief);
    }
    // Nothing cut: the hardware clips at the near plane.
    out.clipDistance = 1.0;
    if (kTileStyleIndexField) {
        out.styleIndex = vertexIn.styleIndex;
        out.lineParameterRaw = f32(vertexIn.lineParameter);
    }
    if (kTileCoverageFields) {
        out.lineDistance = f32(vertexIn.lineDistance) / 127.0;
        out.deferredEdgePx = deferredEdgePx;
        out.widthAxis = widthAxis;
    }
    if (kTileRoadRibbons) {
        // The road's colour is final here.
        let lineStyle = vertexLineStyles[vertexIn.styleIndex];
        out.color = tileLineZoomLook(lineStyle, vertexStyles[vertexIn.styleIndex].color, vertexOverviewFade.cameraZoom);
        out.color.a *= tileStyleFade(vertexStyleZoomFades[vertexIn.styleIndex], vertexOverviewFade);
        out.color.a *= tilePointWidthRampAlpha(lineStyle, vertexOverviewFade.cameraZoom);
        // A road that is invisible this frame is cut whole.
        if (out.color.a <= 0.0) {
            out.clipDistance = -1.0;
        }
    }
    if (kTileFillFields) {
        let style = tileVertexStyle(vertexStyles[vertexIn.styleIndex], vertexStyleZoomFades[vertexIn.styleIndex]);
        out.color = style.color;
        out.color.a *= tileStyleFade(style.zoomFade, vertexOverviewFade);
    }
    return out;
}

/// The point-locked width of a deferred ribbon at this pixel's depth.
/// `position.w` is one over the view depth, in WGSL as in Metal.
fn tileFragmentDeferredEdgePx(in: VertexOut) -> f32 {
    var deferredEdgePx = in.deferredEdgePx;
    if (deferredEdgePx > 0.0 && lineStyles[in.styleIndex].widthPoints > 0.0) {
        let ndc = in.position.xy / max(overviewFade.viewportSizePx, vec2f(1.0)) * vec2f(2.0, -2.0)
            + vec2f(-1.0, 1.0);
        deferredEdgePx *= tilePointWidthPerspectiveScale(overviewFade,
                                                         1.0 / max(in.position.w, 1e-6),
                                                         in.widthAxis,
                                                         ndc);
    }
    return deferredEdgePx;
}

/// How much of the sun reaches the ground at a fragment: the mask on the
/// plane, the cascades on the relief. Metal samples the mask in pixel
/// coordinates, WGSL in normalized ones.
fn tileGroundShadowFactor(in: VertexOut) -> f32 {
    if (kGroundShadowMaskEnabled) {
        if (shadow.strength <= 0.0) {
            return 1.0;
        }
        let maskUV = in.position.xy * kGroundShadowMaskScale / vec2f(textureDimensions(groundShadowMask));
        return textureSampleLevel(groundShadowMask, linearSampler, maskUV, 0.0).r;
    }
    return sampleShadowFactor(shadow, shadowMap, shadowCompareSampler, in.worldPos, vec3f(0.0));
}

@fragment
fn tileFragmentShader(in: VertexOut) -> @location(0) vec4f {
    if (in.clipDistance < 0.0) {
        discard;
    }
    let shadowFactor = tileGroundShadowFactor(in);
    var color: vec4f;
    if (kTileLineFields) {
        let deferredEdgePx = tileFragmentDeferredEdgePx(in);
        color = tileLineFragmentColor(styles[in.styleIndex], styleZoomFades[in.styleIndex], lineStyles[in.styleIndex],
                                      in.lineDistance, in.lineParameterRaw,
                                      overviewFade, lineDash, deferredEdgePx);
    } else {
        color = in.color;
    }
    if (kTileGroundReliefShade) {
        color = vec4f(groundReliefHillshade(color.rgb, in.reliefUV, in.worldPos, reliefHeights, linearSampler, relief),
                      color.a);
        color = vec4f(groundReliefOcclude(color.rgb, in.reliefUV, reliefOcclusion, linearSampler, relief), color.a);
    }
    color = vec4f(color.rgb * shadowColorMultiplier(shadow, shadowFactor), color.a);
    return vec4f(applyGroundFog(color.rgb, in.worldPos, groundFog), color.a);
}

/// The road ribbons: the geometry is the road, so there is no coverage to
/// compute, and the depth test over the rank decides which road owns a
/// pixel (Tile.metal).
@fragment
fn tileRoadFragmentShader(in: VertexOut) -> @location(0) vec4f {
    if (in.clipDistance < 0.0) {
        discard;
    }
    var color = in.color;
    let shadowFactor = tileGroundShadowFactor(in);
    if (kTileRoadBlended) {
        color.a *= alphaScale;
        // The derivative is taken before the discard.
        let parameterSpan = fwidth(in.lineParameterRaw);
        let lineStyle = lineStyles[in.styleIndex];
        // A vanishing gradient is a saturated parameter, not an arc.
        if (lineStyle.dashLengthPoints > 0.0 && parameterSpan > 2e-5) {
            // The arc length rides in half tile units.
            let unitScale = select(lineDash.unitsPerPoint, 1.0, lineStyle.dashInTileUnits > 0.0);
            let dashUnits = lineStyle.dashLengthPoints * unitScale;
            let gapUnits = lineStyle.dashGapPoints * unitScale;
            if (dashUnits > 0.0 && gapUnits > 0.0
                && tileDashEdgeDistance(in.lineParameterRaw * 0.5, dashUnits, dashUnits + gapUnits) < 0.0) {
                discard;
            }
        }
    } else {
        color.a = 1.0;
    }
    color = vec4f(color.rgb * shadowColorMultiplier(shadow, shadowFactor), color.a);
    return vec4f(applyGroundFog(color.rgb, in.worldPos, groundFog), color.a);
}
