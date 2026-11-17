// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: PolygonShader.metal fnv1a64=2a98917a574a56f6
// include: ../../Shaders/Shared/RenderUniforms.wgsl

// The debug overlay's lines and plates (PolygonsPipeline): coloured
// vertices under the camera's matrix, or a screen matrix for what is drawn
// in pixels.

/// Mirror of PolygonsPipeline.Vertex.
struct VertexIn {
    @location(0) position: vec4f,
    @location(1) color: vec4f,
}

struct VertexOut {
    @builtin(position) position: vec4f,
    @location(0) color: vec4f,
}

@group(0) @binding(1) var<uniform> camera: Camera;

@vertex
fn polygonVertexShader(vertexIn: VertexIn) -> VertexOut {
    var out: VertexOut;
    out.position = camera.matrix * vertexIn.position;
    out.color = vertexIn.color;
    return out;
}

@fragment
fn polygonFragmentShader(in: VertexOut) -> @location(0) vec4f {
    return in.color;
}
