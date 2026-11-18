// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: TileShading.h fnv1a64=fdcfe986d743c171
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl

// What the flat ground (Tile.wgsl) and the sphere's ground (TileSphere.wgsl)
// share: the vertex format, the per-style uniforms, the analytic line
// coverage and the zoom fades. TileShading.h explains each.
//
// Metal passes the style tables to these functions as pointers into its
// constant buffers. WGSL passes no pointer into a storage buffer without an
// optional language feature, and the vertex and fragment stages bind the
// tables at different bindings, so the callers index their own tables and
// pass the style's entries in. Metal's half is f32 here: WGSL's f16 is an
// optional feature.

/// Mirror of TileVertexIn (TileVertexLayout.swift), 16 bytes. Metal reads
/// the style index, the side distance and the longitudinal parameter as the
/// integers they are, and so does WGSL: uint8, sint8 and sint16. The
/// normal is snorm8x2, which arrives as floats.
struct VertexIn {
    @location(0) position: vec2f,
    @location(1) styleIndex: u32,
    @location(2) lineDistance: i32,
    @location(3) lineParameter: i32,
    @location(4) normal: vec2f,
}

/// Mirror of TilePolygonStyle: one colour per style.
struct Style {
    color: vec4f,
}

/// Mirror of TileLineStyle, 68 bytes, an element of the line style table.
/// Metal's packed_float3 sphereColor is three floats here, as on the Swift
/// side.
struct LineStyle {
    widthPoints: f32,
    dashLengthPoints: f32,
    dashGapPoints: f32,
    edgeThreshold: f32,
    minimumWidthPoints: f32,
    dashInTileUnits: f32,
    halfWidthUnits: f32,
    worldLockZoom: f32,
    rampStartWidthPoints: f32,
    rampStartZoom: f32,
    rampEndZoom: f32,
    rampStartAlpha: f32,
    sphereAlpha: f32,
    sphereColorRed: f32,
    sphereColorGreen: f32,
    sphereColorBlue: f32,
    sphereLookUntilZoom: f32,
}

fn tileLineSphereColor(lineStyle: LineStyle) -> vec3f {
    return vec3f(lineStyle.sphereColorRed, lineStyle.sphereColorGreen, lineStyle.sphereColorBlue);
}

/// Mirror of TileOverviewFadeUniform. Metal's two packed_float3 ground
/// axes are three floats each, as on the Swift side.
struct OverviewFadeUniform {
    pixelsPerPoint: f32,
    cameraZoom: f32,
    viewportSizePx: vec2f,
    pointWidthReferenceDepth: f32,
    pointWidthCentrePixelsPerWorldUnit: f32,
    groundAxisXClipX: f32,
    groundAxisXClipY: f32,
    groundAxisXClipW: f32,
    groundAxisYClipX: f32,
    groundAxisYClipY: f32,
    groundAxisYClipW: f32,
}

/// Mirror of LineDashUniform: tile units per layout point at the tile's
/// nominal display scale.
struct LineDashUniform {
    unitsPerPoint: f32,
}

/// Whether the style switches its look at a zoom of its own.
fn tileLineSwitchesLookByZoom(lineStyle: LineStyle) -> bool {
    return lineStyle.sphereLookUntilZoom > 0.0;
}

/// A stroke's colour and alpha at the camera zoom: its globe look below its
/// switch zoom, its own from it.
fn tileLineZoomLook(lineStyle: LineStyle, ownColor: vec4f, cameraZoom: f32) -> vec4f {
    if (tileLineSwitchesLookByZoom(lineStyle) && cameraZoom < lineStyle.sphereLookUntilZoom) {
        return vec4f(tileLineSphereColor(lineStyle), ownColor.a * lineStyle.sphereAlpha);
    }
    return ownColor;
}

/// How far a style's zoom ramp has come, 0...1, one for a style without.
fn tilePointWidthRampProgress(lineStyle: LineStyle, cameraZoom: f32) -> f32 {
    if (lineStyle.rampEndZoom <= lineStyle.rampStartZoom) {
        return 1.0;
    }
    return clamp((cameraZoom - lineStyle.rampStartZoom) / (lineStyle.rampEndZoom - lineStyle.rampStartZoom),
                 0.0, 1.0);
}

/// The point-locked width of a style at a camera zoom.
fn tilePointWidthPoints(lineStyle: LineStyle, cameraZoom: f32) -> f32 {
    let progress = tilePointWidthRampProgress(lineStyle, cameraZoom);
    if (progress >= 1.0 || lineStyle.rampStartWidthPoints <= 0.0) {
        return lineStyle.widthPoints;
    }
    return lineStyle.rampStartWidthPoints
        * pow(lineStyle.widthPoints / lineStyle.rampStartWidthPoints, progress);
}

/// The share of the colour's alpha the ramp leaves at a camera zoom.
fn tilePointWidthRampAlpha(lineStyle: LineStyle, cameraZoom: f32) -> f32 {
    return mix(lineStyle.rampStartAlpha, 1.0, tilePointWidthRampProgress(lineStyle, cameraZoom));
}

/// How much wider than its points a point-locked width draws past the
/// style's world lock zoom.
fn tilePointWidthWorldScale(worldLockZoom: f32, cameraZoom: f32) -> f32 {
    if (worldLockZoom <= 0.0) {
        return 1.0;
    }
    return exp2(max(cameraZoom - worldLockZoom, 0.0));
}

/// The visible half-width of a line on screen, in pixels.
fn tileLineEdgePixels(lineStyle: LineStyle,
                      pixelsPerUnit: f32,
                      pixelsPerPoint: f32,
                      cameraZoom: f32) -> f32 {
    if (lineStyle.widthPoints > 0.0) {
        return tilePointWidthPoints(lineStyle, cameraZoom) * 0.5 * pixelsPerPoint
            * tilePointWidthWorldScale(lineStyle.worldLockZoom, cameraZoom);
    }
    var edgePx = lineStyle.halfWidthUnits * pixelsPerUnit;
    if (lineStyle.minimumWidthPoints > 0.0) {
        edgePx = max(edgePx, lineStyle.minimumWidthPoints * 0.5 * pixelsPerPoint);
    }
    return edgePx;
}

/// The feather a deferred ribbon is extruded past its visible edge.
const kTileDeferredRibbonFeatherPx = 1.0;

/// The pixels one world unit of ground spans on screen along `axis` at a
/// point of the screen.
fn tileGroundPixelsPerWorldUnit(axis: vec2f,
                                ndc: vec2f,
                                viewDepth: f32,
                                overviewFade: OverviewFadeUniform) -> f32 {
    let clipStep = vec3f(overviewFade.groundAxisXClipX, overviewFade.groundAxisXClipY, overviewFade.groundAxisXClipW) * axis.x
        + vec3f(overviewFade.groundAxisYClipX, overviewFade.groundAxisYClipY, overviewFade.groundAxisYClipW) * axis.y;
    let halfViewport = overviewFade.viewportSizePx * 0.5;
    return length((clipStep.xy - ndc * clipStep.z) * halfViewport) / max(viewDepth, 1e-6);
}

/// How much a point-locked deferred ribbon's width scales at a point of the
/// screen.
fn tilePointWidthPerspectiveScale(overviewFade: OverviewFadeUniform,
                                  viewDepth: f32,
                                  axis: vec2f,
                                  ndc: vec2f) -> f32 {
    if (overviewFade.pointWidthReferenceDepth <= 0.0) {
        return 1.0;
    }
    if (overviewFade.pointWidthCentrePixelsPerWorldUnit <= 0.0 || dot(axis, axis) <= 1e-6) {
        return overviewFade.pointWidthReferenceDepth / max(viewDepth, 1e-6);
    }
    return tileGroundPixelsPerWorldUnit(normalize(axis), ndc, viewDepth, overviewFade)
        / overviewFade.pointWidthCentrePixelsPerWorldUnit;
}

/// The per-vertex style outputs of a fills vertex: the colour and the zoom
/// fade. Metal's TileVertexStyle also unpacks the line fields, which only
/// tileGroundColor reads, and no stage calls it.
struct TileVertexStyle {
    color: vec4f,
    zoomFade: vec2f,
}

fn tileVertexStyle(style: Style, zoomFade: vec2f) -> TileVertexStyle {
    var out: TileVertexStyle;
    out.color = style.color;
    out.zoomFade = zoomFade;
    return out;
}

/// Metal's round, half away from zero. WGSL's rounds half to even.
fn tileRoundHalfAwayFromZero(x: f32) -> f32 {
    return sign(x) * floor(abs(x) + 0.5);
}

/// The signed distance from a point of a dashed line to the nearest dash
/// boundary: positive inside a dash, negative in a gap. WGSL's % on floats
/// truncates, as Metal's fmod does.
fn tileDashEdgeDistance(lineParameter: f32, dashUnits: f32, period: f32) -> f32 {
    var phase = lineParameter % period;
    if (phase < 0.0) {
        phase += period;
    }
    var centered = phase - dashUnits * 0.5;
    centered -= period * tileRoundHalfAwayFromZero(centered / period);
    return dashUnits * 0.5 - abs(centered);
}

/// Analytic coverage of line geometry, TileShading.h's tileLineCoverage.
/// Takes screen-space derivatives first, so it runs in uniform control flow.
/// `lineStyle` packs the edge threshold, the width, the dash and the gap
/// points.
fn tileLineCoverage(lineDistance: f32,
                    lineParameter: f32,
                    lineStyle: vec4f,
                    minimumWidthPoints: f32,
                    dashInTileUnits: f32,
                    pixelsPerPoint: f32,
                    dashUnitsPerPoint: f32,
                    deferredEdgePx: f32) -> f32 {
    let sideSpan = max(fwidth(lineDistance), 1e-5);
    let parameterSpan = fwidth(lineParameter);
    let edgeThreshold = lineStyle.x;
    if (edgeThreshold <= 0.0) {
        return 1.0;
    }
    let rimPx = 1.0 / sideSpan;
    let widthPoints = lineStyle.y;
    var edgePx: f32;
    if (deferredEdgePx > 0.0) {
        edgePx = min(deferredEdgePx, rimPx - 0.5);
    } else if (widthPoints > 0.0) {
        edgePx = min(widthPoints * 0.5 * pixelsPerPoint, rimPx - 0.5);
    } else {
        edgePx = edgeThreshold * rimPx;
        if (minimumWidthPoints > 0.0) {
            let floorPx = min(minimumWidthPoints * 0.5 * pixelsPerPoint, rimPx - 0.5);
            edgePx = max(edgePx, floorPx);
        }
    }
    let sideDistancePx = edgePx - abs(lineDistance) * rimPx;
    var coverage = smoothstep(-0.5, 0.5, sideDistancePx);

    let dashLengthPoints = lineStyle.z;
    if (dashLengthPoints > 0.0) {
        let unitsPerPixel = parameterSpan;
        let unitScale = select(dashUnitsPerPoint, 1.0, dashInTileUnits > 0.5);
        let dashUnits = dashLengthPoints * unitScale;
        let gapUnits = lineStyle.w * unitScale;
        let period = dashUnits + gapUnits;
        if (unitsPerPixel > 1e-5 && dashUnits > 0.0 && gapUnits > 0.0) {
            let distanceToEdgeUnits = tileDashEdgeDistance(lineParameter, dashUnits, period);
            coverage *= smoothstep(-0.5, 0.5, distanceToEdgeUnits / unitsPerPixel);
        }
    } else {
        let endDistancePx = lineParameter / max(parameterSpan, 1e-5);
        coverage *= smoothstep(-0.5, 0.5, endDistancePx);
    }
    return coverage;
}

/// The zoom fade of a style: x the camera zoom of zero alpha, y of full
/// alpha, a smoothstep between them. Mirrored on the CPU by
/// TileStyleFadeMath.
fn tileStyleFade(zoomFade: vec2f, overviewFade: OverviewFadeUniform) -> f32 {
    let span = zoomFade.y - zoomFade.x;
    var t: f32;
    if (span != 0.0) {
        t = clamp((overviewFade.cameraZoom - zoomFade.x) / span, 0.0, 1.0);
    } else {
        t = step(zoomFade.y, overviewFade.cameraZoom);
    }
    return t * t * (3.0 - 2.0 * t);
}

/// The analytic coverage of a lines-class fragment, apart from the colour.
fn tileLineFragmentCoverage(lineStyle: LineStyle,
                            lineDistance: f32,
                            lineParameterRaw: f32,
                            overviewFade: OverviewFadeUniform,
                            lineDash: LineDashUniform,
                            deferredEdgePx: f32) -> f32 {
    // Arc length in half tile units for a dashed style, the normalized
    // end-feather distance otherwise.
    let lineParameter = select(lineParameterRaw / 32767.0, lineParameterRaw * 0.5, lineStyle.dashLengthPoints > 0.0);
    let widthPoints = select(0.0, tilePointWidthPoints(lineStyle, overviewFade.cameraZoom), lineStyle.widthPoints > 0.0);
    let packedLineStyle = vec4f(lineStyle.edgeThreshold,
                                widthPoints,
                                lineStyle.dashLengthPoints,
                                lineStyle.dashGapPoints);
    return tileLineCoverage(lineDistance,
                            lineParameter,
                            packedLineStyle,
                            lineStyle.minimumWidthPoints,
                            select(0.0, 1.0, lineStyle.dashInTileUnits > 0.0),
                            overviewFade.pixelsPerPoint,
                            lineDash.unitsPerPoint,
                            deferredEdgePx);
}

/// The lines-class fragment's colour from its style's entries: the colour
/// with the zoom look, the zoom fade and the ramp's alpha, times the
/// analytic line coverage.
fn tileLineFragmentColor(style: Style,
                         zoomFade: vec2f,
                         lineStyle: LineStyle,
                         lineDistance: f32,
                         lineParameterRaw: f32,
                         overviewFade: OverviewFadeUniform,
                         lineDash: LineDashUniform,
                         deferredEdgePx: f32) -> vec4f {
    var color = tileLineZoomLook(lineStyle, style.color, overviewFade.cameraZoom);
    color.a *= tileStyleFade(zoomFade, overviewFade);
    color.a *= tilePointWidthRampAlpha(lineStyle, overviewFade.cameraZoom);
    color.a *= tileLineFragmentCoverage(lineStyle, lineDistance, lineParameterRaw,
                                        overviewFade, lineDash, deferredEdgePx);
    return color;
}
