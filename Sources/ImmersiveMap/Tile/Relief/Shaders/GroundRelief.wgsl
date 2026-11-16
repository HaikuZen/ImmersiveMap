// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: GroundRelief.h fnv1a64=6bc9669b150318cd

// The ground relief as the vertex stages read it (GroundReliefStore): the
// ground rises by one bilinear sample of its terrain, scaled by the frame's
// strength, and its fills shade the slopes of the terrain and darken where
// it hides the sky. GroundRelief.h explains the uniform and the shading.
// Metal's `groundReliefSampler` is declared in the shader: here it is the
// linear sampler the WebGPU backend binds at 49 of the stage's group
// (RenderUniforms.wgsl), which the callers pass in.

/// Mirror of GroundReliefUniform.swift (vertex and fragment binding 9).
struct GroundReliefUniform {
    placement: vec4f,
    frame: vec4f,
    hillshadeLight: vec4f,
    hillshadeShadowColor: vec4f,
    hillshadeHighlightColor: vec4f,
    hillshadeEye: vec4f,
    hillshadeFade: vec4f,
    shading: vec4f,
    occlusion: vec4f,
}

/// The texture's uv of a tile-local point: the point is render space (y
/// up), the texture's row 0 is the north edge.
fn groundReliefTileUV(localPosition: vec2f) -> vec2f {
    return saturate(vec2f(localPosition.x, 4096.0 - localPosition.y) / 4096.0);
}

/// Where a tile-local point lies in the terrain texture the grid rises by.
fn groundReliefTextureUV(localPosition: vec2f, relief: GroundReliefUniform) -> vec2f {
    return relief.placement.xy + groundReliefTileUV(localPosition) * relief.placement.z;
}

/// Where a tile-local point lies in the terrain texture the slopes are
/// shaded by.
fn groundReliefShadingUV(localPosition: vec2f, relief: GroundReliefUniform) -> vec2f {
    return relief.shading.xy + groundReliefTileUV(localPosition) * relief.shading.z;
}

/// The terrain's height in metres under a tile-local point.
fn groundReliefHeight(localPosition: vec2f,
                      heights: texture_2d<f32>,
                      reliefSampler: sampler,
                      relief: GroundReliefUniform) -> f32 {
    return textureSampleLevel(heights, reliefSampler, groundReliefTextureUV(localPosition, relief), 0.0).r;
}

/// The world z a tile-local point rises to over the plane: its terrain's
/// height over the datum, in world units, at the frame's strength.
fn groundReliefLift(localPosition: vec2f,
                    heights: texture_2d<f32>,
                    reliefSampler: sampler,
                    relief: GroundReliefUniform) -> f32 {
    let metres = groundReliefHeight(localPosition, heights, reliefSampler, relief) - relief.frame.x;
    return metres * relief.frame.y * relief.placement.w;
}

/// A colour of the ground with its slope shaded at a point of the shading's
/// terrain texture, faded out with the point's distance from the eye.
fn groundReliefHillshade(color: vec3f,
                         textureUV: vec2f,
                         worldPosition: vec3f,
                         heights: texture_2d<f32>,
                         reliefSampler: sampler,
                         relief: GroundReliefUniform) -> vec3f {
    let faded = saturate((distance(worldPosition, relief.hillshadeEye.xyz) - relief.hillshadeFade.x)
                         * relief.hillshadeFade.y);
    let amount = relief.hillshadeLight.w * (1.0 - faded * faded * (3.0 - 2.0 * faded));
    if (amount <= 0.0) {
        return color;
    }
    let texel = 1.0 / vec2f(textureDimensions(heights));
    let east = textureSampleLevel(heights, reliefSampler, textureUV + vec2f(texel.x, 0.0), 0.0).r
        - textureSampleLevel(heights, reliefSampler, textureUV - vec2f(texel.x, 0.0), 0.0).r;
    // The texture's rows run south.
    let north = textureSampleLevel(heights, reliefSampler, textureUV - vec2f(0.0, texel.y), 0.0).r
        - textureSampleLevel(heights, reliefSampler, textureUV + vec2f(0.0, texel.y), 0.0).r;
    let span = 2.0 * texel * max(relief.frame.z, 1e-3);
    let normal = normalize(vec3f(-east / span.x, -north / span.y, 1.0));
    let light = relief.hillshadeLight.xyz;
    // Zero on level ground, one for a slope square to the light, minus one
    // for one the light grazes.
    let facing = dot(normal, light) - light.z;
    let lit = select(facing / max(light.z, 1e-3), facing / max(1.0 - light.z, 1e-3), facing >= 0.0);
    let tint = select(relief.hillshadeShadowColor, relief.hillshadeHighlightColor, lit >= 0.0);
    let share = saturate(abs(lit) * amount) * tint.a;
    return mix(color, tint.rgb, share);
}

/// A colour of the ground darkened by how much the terrain around the point
/// hides the sky. The debug view draws the occlusion alone: white for the
/// open sky, black for none.
fn groundReliefOcclude(color: vec3f,
                       textureUV: vec2f,
                       occlusion: texture_2d<f32>,
                       reliefSampler: sampler,
                       relief: GroundReliefUniform) -> vec3f {
    if (relief.occlusion.x <= 0.0 && relief.occlusion.y <= 0.0) {
        return color;
    }
    let occluded = textureSampleLevel(occlusion, reliefSampler, textureUV, 0.0).r;
    if (relief.occlusion.y > 0.0) {
        return vec3f(1.0 - occluded);
    }
    return color * (1.0 - relief.occlusion.x * occluded);
}
