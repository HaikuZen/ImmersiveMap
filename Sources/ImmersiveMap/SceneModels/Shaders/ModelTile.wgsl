// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: ModelTile.metal fnv1a64=797b1f3868e737e2
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl

// The models of a model tile (ModelTilePipeline): every model of the tile
// in one vertex buffer and one index buffer, in the tile's own space, with
// one texture array, so a tile draws in one call under one matrix.
// ModelTile.metal explains the space, the depth bias and the clipped
// variant.

/// The clipped variant of the fragment stage: the fragments below the
/// ground, the plane Z = 0, are dropped.
@id(0) override kModelTileClipsBelowGround: bool;

/// The vertex of a model tile, as the baker wrote it (ModelTileContents).
struct VertexIn {
    @location(0) position: vec3f,
    /// Signed normalized bytes, read as four (WebGPU has no three-byte
    /// format): the fourth is the layer's byte, left unread.
    @location(1) normal: vec3f,
    /// The layer of the tile's texture array.
    @location(2) layer: u32,
    /// Unsigned normalized shorts, V down: the origin is the top left of
    /// the image.
    @location(3) uv: vec2f,
}

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    @location(1) worldNormal: vec3f,
    @location(2) uv: vec2f,
    @location(3) @interpolate(flat) layer: u32,
}

@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(2) var<uniform> modelMatrix: mat4x4f;
@group(0) @binding(3) var<uniform> depthBias: f32;

@group(1) @binding(4) var<uniform> shadow: Shadow;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;
@group(1) @binding(16) var baseColorTextures: texture_2d_array<f32>;
@group(1) @binding(17) var shadowMap: texture_depth_2d_array;
@group(1) @binding(32) var baseColorSampler: sampler;
@group(1) @binding(48) var shadowCompareSampler: sampler_comparison;

/// Every vertex moves toward the eye along its own ray by `depthBias` of
/// its distance: where it is on the screen stays, its depth comes forward.
@vertex
fn modelTileVertexShader(vertexIn: VertexIn) -> VertexOut {
    let worldPosition = modelMatrix * vec4f(vertexIn.position, 1.0);
    let drawnPosition = worldPosition.xyz + (camera.eye - worldPosition.xyz) * depthBias;

    var out: VertexOut;
    out.position = camera.matrix * vec4f(drawnPosition, 1.0);
    out.worldPosition = worldPosition.xyz;
    // A translation and a uniform scale leave a direction as it is.
    out.worldNormal = normalize(vertexIn.normal);
    out.uv = vertexIn.uv;
    out.layer = vertexIn.layer;
    return out;
}

/// No analytic lighting, as the buildings and the scene models: the
/// texture's colour darkens only where the shadow map says the sun is
/// occluded, sampled raw with no sRGB decode.
@fragment
fn modelTileFragmentShader(in: VertexOut) -> @location(0) vec4f {
    if (kModelTileClipsBelowGround && in.worldPosition.z < 0.0) {
        discard;
    }
    let base = textureSample(baseColorTextures, baseColorSampler, in.uv, in.layer);
    let shadowFactor = sampleShadowFactor(shadow, shadowMap, shadowCompareSampler, in.worldPosition, in.worldNormal);
    let lit = base.rgb * shadowColorMultiplier(shadow, shadowFactor);
    return vec4f(applyGroundFog(lit, in.worldPosition, groundFog), 1.0);
}

// The depth-only caster pass: one draw a tile into a plain 2D depth
// attachment.
@group(0) @binding(1) var<uniform> casters: ShadowCasterMatrices;

@vertex
fn modelTileShadowVertexShader(vertexIn: VertexIn) -> @builtin(position) vec4f {
    return casterClipPosition(casters.lightProjectionView * (modelMatrix * vec4f(vertexIn.position, 1.0)));
}
