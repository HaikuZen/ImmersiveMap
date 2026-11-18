// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: RouteShield.metal fnv1a64=83657e2562607025
// include: ../Shared/LabelTextCommon.wgsl

// The plate behind a route number, drawn from its distance field. The quad
// is placed by poiSpriteVertex like a POI disc: its uv carries the plate's
// size in layout points and its spriteUV the corner, so the distances
// below are in points and the antialiasing reads the screen's own rate of
// change of them. Layout space is y up.

/// Mirrors RouteShieldStyleUniform.
struct RouteShieldStyle {
    fillColor: vec4f,
    borderColor: vec4f,
    headerColor: vec4f,
    borderWidthPoints: f32,
    cornerRadiusPoints: f32,
    headerFraction: f32,
    shape: u32,
}

/// RouteShieldAppearance.Shape: 0 is the rectangle, the default branch.
const kRouteShieldCapsule: u32 = 1u;
const kRouteShieldEscutcheon: u32 = 2u;

@group(1) @binding(0) var<uniform> style: RouteShieldStyle;

fn roundedBoxDistance(p: vec2f, halfSize: vec2f, radius: f32) -> f32 {
    let r = min(radius, min(halfSize.x, halfSize.y));
    let q = abs(p) - halfSize + r;
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

/// A heraldic shield: the box down to where the sides start to curve, and
/// below that the lens two circles cut, meeting in a point at the bottom.
fn escutcheonDistance(p: vec2f, halfSize: vec2f, radius: f32) -> f32 {
    let box = roundedBoxDistance(p, halfSize, radius);
    let depth = min(1.15 * halfSize.x, 1.6 * halfSize.y);
    let shoulder = -halfSize.y + depth;
    if (p.y >= shoulder) {
        return box;
    }
    let centreOffset = max((depth * depth - halfSize.x * halfSize.x) / (2.0 * halfSize.x), 0.0);
    let arcRadius = halfSize.x + centreOffset;
    let left = length(p - vec2f(-centreOffset, shoulder)) - arcRadius;
    let right = length(p - vec2f(centreOffset, shoulder)) - arcRadius;
    return max(box, max(left, right));
}

@fragment
fn routeShieldFragment(in: VertexOut) -> @location(0) vec4f {
    let size = in.uv;
    let halfSize = size * 0.5;
    let p = (in.spriteUV - 0.5) * size;

    var distance: f32;
    if (style.shape == kRouteShieldCapsule) {
        distance = roundedBoxDistance(p, halfSize, min(halfSize.x, halfSize.y));
    } else if (style.shape == kRouteShieldEscutcheon) {
        distance = escutcheonDistance(p, halfSize, style.cornerRadiusPoints);
    } else {
        distance = roundedBoxDistance(p, halfSize, style.cornerRadiusPoints);
    }

    let aa = max(fwidth(distance), 1.0e-4);
    let coverage = saturate(0.5 - distance / aa);
    var inside = 1.0;
    if (style.borderWidthPoints > 0.0) {
        inside = saturate(0.5 - (distance + style.borderWidthPoints) / aa);
    }

    var body = style.fillColor.rgb;
    if (style.headerFraction > 0.0) {
        let headerEdge = halfSize.y - size.y * style.headerFraction;
        let headerAA = max(fwidth(p.y), 1.0e-4);
        let header = saturate(0.5 + (p.y - headerEdge) / headerAA);
        body = mix(body, style.headerColor.rgb, header);
    }
    let color = mix(style.borderColor.rgb, body, inside);
    return vec4f(color, coverage * in.alpha);
}
