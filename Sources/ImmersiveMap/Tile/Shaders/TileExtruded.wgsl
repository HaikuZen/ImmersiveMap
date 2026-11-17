// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: TileExtruded.metal fnv1a64=47a2dc73a77225f3
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl

// The extruded buildings (ExtrudedTilePipeline): flat base colours,
// darkened where the shadow map says the sun is occluded, two tonal depth
// cues, the ground fog, and the depth-only caster pass. TileExtruded.metal
// explains the shading.

/// The ground relief: the building rises by its lift, one per building of
/// the tile at vertex binding 4, as BuildingLift says. On WebGPU bindings 4
/// and 5 stay in the pipeline's layout with the constant off, as an
/// override removes no binding, and the backend binds a placeholder there.
@id(0) override kExtrudedRelief: bool;

/// Mirror of BuildingLiftUniform.
struct BuildingLift {
    unitsPerMetre: f32,
    datumMetres: f32,
    strength: f32,
    padding: f32,
}

/// The world z a building rises by: its lift's metres over the datum at the
/// frame's strength.
fn buildingLiftZ(lift: f32, uniform: BuildingLift) -> f32 {
    return (lift - uniform.datumMetres) * uniform.strength * uniform.unitsPerMetre;
}

/// The CPU quantizes positions to quarter tile units (ExtrudedVertexIn).
const kExtrudedPositionInverseScale = 0.25;

/// Mirror of ExtrudedVertexIn, 12 bytes. Metal converts the raw Int16
/// position to float on fetch, WebGPU converts no integer: it arrives as
/// integers (short3, read as sint16x4) and is converted here. The normal is
/// snorm8, slightly short of unit length until the normalize below.
struct VertexIn {
    @location(0) position: vec3<i32>,
    @location(1) normal: vec3f,
    @location(2) styleIndex: u32,
    @location(3) buildingOrdinal: u32,
}

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    @location(1) worldNormal: vec3f,
    @location(2) color: vec4f,
}

/// Mirror of TilePolygonStyle: the stride must match the shared style
/// buffer.
struct Style {
    color: vec4f,
}

@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(2) var<storage, read> styles: array<Style>;
@group(0) @binding(3) var<uniform> modelMatrix: mat4x4f;
@group(0) @binding(4) var<storage, read> buildingLifts: array<f32>;
@group(0) @binding(5) var<uniform> lift: BuildingLift;

@group(1) @binding(5) var<uniform> shadow: Shadow;
@group(1) @binding(6) var<uniform> metersToWorldZ: f32;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;
@group(1) @binding(16) var shadowMap: texture_depth_2d_array;
@group(1) @binding(48) var shadowCompareSampler: sampler_comparison;

fn extrudedWorldPosition(vertexIn: VertexIn) -> vec4f {
    let localPosition = vec3f(vertexIn.position) * kExtrudedPositionInverseScale;
    var worldPosition = modelMatrix * vec4f(localPosition, 1.0);
    if (kExtrudedRelief) {
        worldPosition.z += buildingLiftZ(buildingLifts[vertexIn.buildingOrdinal], lift);
    }
    return worldPosition;
}

@vertex
fn tileExtrudedVertexShader(vertexIn: VertexIn) -> VertexOut {
    let style = styles[vertexIn.styleIndex];
    let worldPosition = extrudedWorldPosition(vertexIn);
    let normalMatrix = mat3x3f(modelMatrix[0].xyz, modelMatrix[1].xyz, modelMatrix[2].xyz);

    var out: VertexOut;
    out.position = camera.matrix * worldPosition;
    out.color = style.color;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = normalize(normalMatrix * vertexIn.normal);
    return out;
}

// The depth cues: two tonal terms that never exceed 1. Roofs keep the base
// colour, walls darken slightly and more on the side away from the sun, and
// walls darken toward the ground.
const kWallShadeBase = 0.90;
const kWallShadeSunSwing = 0.07;
const kBaseDarkening = 0.88;
const kGradientRampMeters = 30.0;

fn extrudedDepthCueShade(worldNormal: vec3f, heightMeters: f32, lightDirection: vec3f) -> f32 {
    let upness = saturate(worldNormal.z);

    var sunSide = 0.0;
    let horizontalNormal = worldNormal.xy;
    let horizontalSun = lightDirection.xy;
    let normalLength = length(horizontalNormal);
    let sunLength = length(horizontalSun);
    // Roof fragments and the vertical placeholder sun keep the neutral wall
    // tone.
    if (normalLength > 1.0e-3 && sunLength > 1.0e-3) {
        sunSide = dot(horizontalNormal / normalLength, horizontalSun / sunLength);
    }
    let wallShade = kWallShadeBase + kWallShadeSunSwing * sunSide;
    let orientationShade = mix(wallShade, 1.0, upness);

    let gradient = mix(kBaseDarkening, 1.0, smoothstep(0.0, kGradientRampMeters, heightMeters));
    return orientationShade * gradient;
}

@fragment
fn tileExtrudedFragmentShader(in: VertexOut) -> @location(0) vec4f {
    let shadowFactor = sampleShadowFactor(shadow, shadowMap, shadowCompareSampler, in.worldPosition, in.worldNormal);
    let heightMeters = in.worldPosition.z / max(metersToWorldZ, 1e-9);
    let depthCueShade = extrudedDepthCueShade(in.worldNormal, min(heightMeters, 1.0e4), shadow.lightDirection);
    // The cues fade out with the shadow factor, and the factor is applied
    // through the tinted multiplier, the ground's shadow colour.
    let appliedCue = mix(1.0, depthCueShade, shadowFactor);
    let color = in.color.rgb * appliedCue * shadowColorMultiplier(shadow, shadowFactor);
    return vec4f(applyGroundFog(color, in.worldPosition, groundFog), 1.0);
}

// The depth-only caster pass: one shadow window, one draw per geometry
// into a plain 2D depth attachment.
@group(0) @binding(1) var<uniform> casters: ShadowCasterMatrices;

@vertex
fn tileExtrudedShadowVertexShader(vertexIn: VertexIn) -> @builtin(position) vec4f {
    return casterClipPosition(casters.lightProjectionView * extrudedWorldPosition(vertexIn));
}
