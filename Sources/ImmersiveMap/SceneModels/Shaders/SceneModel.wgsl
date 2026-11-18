// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: SceneModel.metal fnv1a64=5c66ec98234ec6ce
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl

// The scene models (SceneModelPipeline): a rigid mesh placed by its model
// matrix, the base colour darkened where the shadow map says the sun is
// occluded, the ground fog, the ground cut's footprint and the depth-only
// caster pass. SceneModel.metal explains the ground cut.

/// The clipped variant of the fragment stage: below-ground fragments are
/// dropped.
@id(0) override kSceneModelClipsBelowGround: bool;

/// The canonical interleaved layout of SceneModelAssetLoader: position,
/// normal and texture coordinates, 32 bytes.
struct VertexIn {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) uv: vec2f,
}

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    @location(1) worldNormal: vec3f,
    @location(2) uv: vec2f,
    /// Height above the map surface under the anchor, in render units:
    /// negative below the ground. Linear in the position, so it
    /// interpolates exactly.
    @location(3) groundHeight: f32,
}

/// Mirror of SceneModelDrawer.SceneModelMaterialUniform.
struct SceneModelMaterial {
    baseColor: vec4f,
}

/// Mirror of SceneModelGroundPlane: the surface point under the anchor at
/// altitude zero and the local up.
struct SceneModelGroundPlane {
    @size(16) surfacePosition: vec3f,
    @size(16) up: vec3f,
}

@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(2) var<uniform> modelMatrix: mat4x4f;
@group(0) @binding(3) var<uniform> normalMatrix: mat3x3f;
@group(0) @binding(4) var<uniform> ground: SceneModelGroundPlane;

@group(1) @binding(3) var<uniform> material: SceneModelMaterial;
@group(1) @binding(4) var<uniform> shadow: Shadow;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;
@group(1) @binding(16) var baseColorTexture: texture_2d<f32>;
@group(1) @binding(17) var shadowMap: texture_depth_2d_array;
@group(1) @binding(32) var baseColorSampler: sampler;
@group(1) @binding(48) var shadowCompareSampler: sampler_comparison;

@vertex
fn sceneModelVertexShader(vertexIn: VertexIn) -> VertexOut {
    let worldPosition = modelMatrix * vec4f(vertexIn.position, 1.0);

    var out: VertexOut;
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = normalize(normalMatrix * vertexIn.normal);
    // Model I/O content authors texture coordinates with a bottom-left
    // origin, sampled top-left: V flips here.
    out.uv = vec2f(vertexIn.uv.x, 1.0 - vertexIn.uv.y);
    out.groundHeight = dot(worldPosition.xyz - ground.surfacePosition, ground.up);
    return out;
}

/// The ground hole of a model that cuts into the ground: every vertex
/// projected onto the ground plane along the up vector, so the mesh
/// rasterises as its outline on the surface. The pipeline has no fragment
/// stage, the draw's stencil state raises or lowers the ground hole bit.
@vertex
fn sceneModelGroundFootprintVertexShader(vertexIn: VertexIn) -> @builtin(position) vec4f {
    let worldPosition = (modelMatrix * vec4f(vertexIn.position, 1.0)).xyz;
    let height = dot(worldPosition - ground.surfacePosition, ground.up);
    return camera.matrix * vec4f(worldPosition - ground.up * height, 1.0);
}

/// No analytic lighting model, as the buildings: the base colour darkens
/// only where the shadow map says the static sun is occluded.
@fragment
fn sceneModelFragmentShader(in: VertexOut) -> @location(0) vec4f {
    if (kSceneModelClipsBelowGround && in.groundHeight < 0.0) {
        discard;
    }
    let base = textureSample(baseColorTexture, baseColorSampler, in.uv) * material.baseColor;
    let shadowFactor = sampleShadowFactor(shadow, shadowMap, shadowCompareSampler, in.worldPosition, in.worldNormal);
    let lit = base.rgb * shadowColorMultiplier(shadow, shadowFactor);
    return vec4f(applyGroundFog(lit, in.worldPosition, groundFog), 1.0);
}

// The depth-only caster pass: one shadow window, one draw per geometry
// into a plain 2D depth attachment.
@group(0) @binding(1) var<uniform> casters: ShadowCasterMatrices;

@vertex
fn sceneModelShadowVertexShader(vertexIn: VertexIn) -> @builtin(position) vec4f {
    return casterClipPosition(casters.lightProjectionView * (modelMatrix * vec4f(vertexIn.position, 1.0)));
}
