// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: Globe.metal fnv1a64=4f140b1f6d709aeb
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: GlobeLight.wgsl

// The polar caps (GlobeCapPipeline): the sphere past the tiles' latitudes,
// one constant colour a cap, lit by the globe's sun, fading out early in the
// unroll.

struct CapVertexIn {
    @location(0) latLon: vec2f,
}

struct CapVertexOut {
    @builtin(position) position: vec4f,
    @location(0) capAlpha: f32,
    /// The sphere's normal in world space, the sun's side (GlobeLight.wgsl).
    @location(1) sphereNormal: vec3f,
}

/// One cap's constant colour, straight from the style palette (the north cap
/// is the open ocean, the south the polar ice). Mirrors GlobeCapParams.
struct CapParams {
    color: vec4f,
}

@group(0) @binding(2) var<uniform> globe: Globe;
@group(0) @binding(10) var<uniform> globeFrame: GlobeFrameConstants;
@group(1) @binding(0) var<uniform> params: CapParams;
@group(1) @binding(9) var<uniform> globeLight: GlobeLight;

const halfPi = 1.5707963267948966;

@vertex
fn globeCapVertexShader(vertexIn: CapVertexIn) -> CapVertexOut {
    // Cap geometry stores geographic latitude directly. The globe tile path
    // uses phi = geographicLatitude - pi/2 after Mercator->sphere
    // conversion, so caps must use the same convention or north/south
    // hemispheres get swapped. The longitude keeps the cap's own origin.
    let phi = vertexIn.latLon.x - halfPi;
    let theta = vertexIn.latLon.y;
    let unitDirection = vec3f(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta));

    // The cap does not morph into the plane: during the unfurl it diverges
    // from the tile surface, so it fades out in the first third of the
    // transition, while the divergence is not yet noticeable.
    let capFadeEndTransition = 0.35;
    let transitionFade = smoothstep(0.0, capFadeEndTransition, clamp(globe.transition, 0.0, 1.0));

    var out: CapVertexOut;
    // One composed matrix (camera x translate x pan rotation x radius),
    // built once per frame on the CPU.
    out.position = globeFrame.sphereClip * vec4f(unitDirection, 1.0);
    out.capAlpha = 1.0 - transitionFade;
    out.sphereNormal = (globeFrame.sphereWorld * vec4f(unitDirection, 0.0)).xyz;
    return out;
}

@fragment
fn globeCapFragmentShader(in: CapVertexOut) -> @location(0) vec4f {
    // Opaque surface colour: the cap is planet, and only the unfurl's fade
    // thins it out.
    let lit = globeLitColor(params.color.rgb, in.sphereNormal, globeLight);
    return vec4f(lit, in.capAlpha);
}
