// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: PinBeam.metal fnv1a64=af38f20e995773b6
// include: PinCommon.wgsl

// Reveal thresholds match PinCollisionMath.displacedMorph*:
// the beam appears together with the displaced pin morphing into a circle.
const kDisplacedRevealStartPx: f32 = 2.0;
const kDisplacedRevealEndPx: f32 = 10.0;

@group(0) @binding(0) var<uniform> screenMatrix: mat4x4f;
@group(0) @binding(1) var<storage, read> points: array<ScreenPointOutput>;
@group(0) @binding(2) var<storage, read> offsets: array<PinOffset>;
@group(0) @binding(3) var<uniform> beamStyle: PinBeamStyleGPU;

@group(1) @binding(0) var<uniform> beamColor: vec4f;

fn beamReveal(displacementLength: f32) -> f32 {
    return smoothstep(kDisplacedRevealStartPx, kDisplacedRevealEndPx, displacementLength);
}

struct BeamVertexOut {
    @builtin(position) position: vec4f,
    @location(0) alpha: f32,
    /// 0 at the geo point, 1 at the circle: the beam fades as it nears the geo point.
    @location(1) taper: f32,
}

// Cone from the geo point to the displaced circle: apex at the anchor, base at
// the two tangent points of the body circle ("edge to edge"). Drawn only for
// circles: an undisplaced pin has zero offset and the cone is hidden.
@vertex
fn pinBeamVertex(@builtin(vertex_index) vid: u32,
                 @builtin(instance_index) iid: u32) -> BeamVertexOut {
    var triIndices = array<u32, 6>(0u, 1u, 2u, 0u, 2u, 1u);

    var out: BeamVertexOut;
    out.position = vec4f(-2.0, -2.0, 0.0, 1.0);
    out.alpha = 0.0;
    out.taper = 0.0;

    let point = points[iid];
    let offset = offsets[iid];
    if (point.visible == 0u) {
        return out;
    }

    let anchor = point.position;
    let bubbleCenter = anchor + offset.value + beamStyle.pinCenterOffsetPx * offset.scale;
    let direction = bubbleCenter - anchor;
    let len = length(direction);
    let radius = max(beamStyle.pinBodyHalfMinPx * offset.scale, 1.0);
    if (len <= radius + 1.0) {
        return out;
    }

    let alpha = beamReveal(length(offset.value)) * point.visibilityAlpha;
    if (alpha <= 0.001) {
        return out;
    }

    let dirNorm = direction / len;
    let perp = vec2f(-dirNorm.y, dirNorm.x);
    let tangentX = -radius * radius / len;
    let tangentY = radius * sqrt(max(len * len - radius * radius, 0.0)) / len;
    let tangentLeft = bubbleCenter + dirNorm * tangentX + perp * tangentY;
    let tangentRight = bubbleCenter + dirNorm * tangentX - perp * tangentY;

    var corners = array<vec2f, 3>(anchor, tangentLeft, tangentRight);
    var cornerTapers = array<f32, 3>(0.0, 1.0, 1.0);

    let corner = triIndices[vid];
    out.position = screenMatrix * vec4f(corners[corner], 0.0, 1.0);
    out.alpha = alpha;
    out.taper = cornerTapers[corner];
    return out;
}

@fragment
fn pinBeamFragment(in: BeamVertexOut) -> @location(0) vec4f {
    // Falloff toward the geo point by the power of 1.5: the beam is dense at
    // the circle and dissolves before the cone apex at the actual geo point.
    var taper = in.taper;
    taper = taper * sqrt(taper);
    return vec4f(beamColor.rgb, beamColor.a * in.alpha * taper);
}
