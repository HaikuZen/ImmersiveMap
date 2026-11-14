// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: Trees.metal fnv1a64=c2994002d02e6fd1
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../Render/Shaders/Shared/GroundFog.wgsl
// include: ../../Render/Shaders/Shared/GeoMath.wgsl

// The trees of the flat map: the tree model drawn once per tree of a tile,
// each turned about its trunk, scaled to its height and stood at its point
// in the tile's space, then taken into the world by the tile's matrix. Their
// shadows are a soft disc each, multiplied into the ground. Trees.metal
// explains both. instance_index counts from the draw's first instance, as
// Metal's instance_id does. WebGPU binds a storage buffer only at an offset
// that is a multiple of 256, so on WebGPU a run of a tile's trees is bound
// at the tile's span and chosen by the first instance, not by an offset
// into the span.

/// Mirror of TreeInstance.swift (vertex binding 4), 16 bytes.
struct TreeInstance {
    position: vec2f,
    height: f32,
    packed: u32,
}

/// Mirror of TreeTileUniform in TreeDrawer.swift (vertex binding 3).
struct TreeTile {
    modelMatrix: mat4x4f,
    /// What a unit of the model's height is in the model's own metres,
    /// times the tile's rise out of the ground.
    heightScale: f32,
    @size(16) padding: vec3f,
}

/// Mirror of TreeFrameUniform in TreeDrawer.swift (vertex and fragment
/// binding 7): the direction towards the light, the palette, and the
/// crown's radius and the height of its centre in the model's metres.
struct TreeFrame {
    lightDirection: vec4f,
    crownColor: vec4f,
    crownShadeColor: vec4f,
    trunkColor: vec4f,
    crown: vec4f,
}

/// The model's vertex (TreeModelContents): `shading.x` is how far up the
/// crown or the trunk the point lies, `shading.y` 1 on the trunk and 0 on
/// the crown.
struct TreeVertexIn {
    @location(0) position: vec3f,
    @location(1) normal: vec4f,
    @location(2) shading: vec4f,
}

struct TreeVertexOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    @location(1) worldNormal: vec3f,
    @location(2) color: vec4f,
}

@group(0) @binding(1) var<uniform> camera: Camera;
@group(0) @binding(3) var<uniform> tile: TreeTile;
@group(0) @binding(4) var<storage, read> instances: array<TreeInstance>;
@group(0) @binding(7) var<uniform> frame: TreeFrame;

@group(1) @binding(5) var<uniform> shadow: Shadow;
@group(1) @binding(7) var<uniform> fragmentFrame: TreeFrame;
@group(1) @binding(12) var<uniform> groundFog: GroundFog;

fn turned(point: vec2f, sinTurn: f32, cosTurn: f32) -> vec2f {
    return vec2f(point.x * cosTurn - point.y * sinTurn,
                 point.x * sinTurn + point.y * cosTurn);
}

@vertex
fn treeVertexShader(vertexIn: TreeVertexIn, @builtin(instance_index) instanceID: u32) -> TreeVertexOut {
    let instance = instances[instanceID];
    let turn = f32(instance.packed & 0xFFFFu) / 65535.0 * 2.0 * kPi;
    let tint = f32((instance.packed >> 16u) & 0xFFu) / 255.0;
    let sinTurn = sin(turn);
    let cosTurn = cos(turn);
    let scale = instance.height * tile.heightScale;

    let local = vertexIn.position * scale;
    let placed = vec3f(turned(local.xy, sinTurn, cosTurn) + instance.position, local.z);
    let worldPosition = tile.modelMatrix * vec4f(placed, 1.0);

    let normal = vertexIn.normal.xyz;
    let turnedNormal = vec3f(turned(normal.xy, sinTurn, cosTurn), normal.z);
    let normalMatrix = mat3x3f(tile.modelMatrix[0].xyz, tile.modelMatrix[1].xyz, tile.modelMatrix[2].xyz);

    var out: TreeVertexOut;
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.worldNormal = normalize(normalMatrix * turnedNormal);
    // The palette's colours by the point's part and depth in the crown,
    // tinted from a shade darker to a shade lighter, so a wood is not one
    // green.
    let crown = mix(frame.crownShadeColor.rgb, frame.crownColor.rgb, vertexIn.shading.x);
    let trunk = frame.trunkColor.rgb * (0.85 + 0.2 * vertexIn.shading.x);
    let color = select(crown, trunk, vertexIn.shading.y > 0.5);
    out.color = vec4f(color * (0.86 + 0.28 * tint), 1.0);
    return out;
}

/// A soft directional light over the palette's colours, the sun side a
/// little brighter, so the crown reads as a volume. No shadow map.
@fragment
fn treeFragmentShader(in: TreeVertexOut) -> @location(0) vec4f {
    let normal = normalize(in.worldNormal);
    let diffuse = max(dot(normal, fragmentFrame.lightDirection.xyz), 0.0);
    let shade = 0.68 + 0.26 * diffuse + 0.06 * saturate(normal.z);
    return vec4f(applyGroundFog(in.color.rgb * shade, in.worldPosition, groundFog), 1.0);
}

/// The shadow disc: one quad per instance, two triangles from the vertex
/// index, in the tile's space on the ground, the crown's shadow ellipse.
struct TreeShadowVertexOut {
    @builtin(position) position: vec4f,
    @location(0) worldPosition: vec3f,
    /// The disc's own coordinates, the rim at length one.
    @location(1) disc: vec2f,
}

@vertex
fn treeShadowVertexShader(@builtin(vertex_index) vertexID: u32,
                          @builtin(instance_index) instanceID: u32) -> TreeShadowVertexOut {
    var corners = array<vec2f, 6>(vec2f(-1.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
                                  vec2f(-1.0, -1.0), vec2f(1.0, 1.0), vec2f(-1.0, 1.0));
    let instance = instances[instanceID];
    let unitsPerMetre = instance.height * tile.heightScale;
    let radius = frame.crown.x * unitsPerMetre;
    let centreHeight = frame.crown.y * unitsPerMetre;

    let light = frame.lightDirection.xyz;
    // The sun never below a fifth of the sky, so the ellipse and the offset
    // stay in bounds whatever the settings say.
    let lightZ = max(light.z, 0.2);
    let horizontal = light.xy;
    let horizontalLength = length(horizontal);
    var along = vec2f(1.0, 0.0);
    if (horizontalLength > 1.0e-4) {
        along = horizontal / horizontalLength;
    }
    let across = vec2f(-along.y, along.x);

    let disc = corners[vertexID % 6u];
    let centre = instance.position - along * (horizontalLength / lightZ) * centreHeight;
    let point = centre + along * (disc.x * radius / lightZ) + across * (disc.y * radius);
    let worldPosition = tile.modelMatrix * vec4f(point, 0.0, 1.0);

    var out: TreeShadowVertexOut;
    out.position = camera.matrix * worldPosition;
    out.worldPosition = worldPosition.xyz;
    out.disc = disc;
    return out;
}

/// The darkening of the ground under the disc: full inside, feathered to
/// nothing at the rim, faded with the distance as the shadow map's shadows
/// are and gone into the fog, written as the multiplier the ground takes.
@fragment
fn treeShadowFragmentShader(in: TreeShadowVertexOut) -> @location(0) vec4f {
    let distance = length(in.disc);
    var coverage = 1.0 - smoothstep(0.55, 1.0, distance);
    coverage *= shadowCascadeBlend(shadow, in.worldPosition.xy).fade;
    coverage *= 1.0 - groundFogAmount(in.worldPosition, groundFog);
    let multiplier = shadowColorMultiplier(shadow, 1.0 - coverage * shadow.strength);
    return vec4f(multiplier, 1.0);
}
