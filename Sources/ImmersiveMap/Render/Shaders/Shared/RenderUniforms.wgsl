// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: RenderUniforms.h fnv1a64=2cc0d28bd7943bda

// The uniforms the WGSL stages share: the twins of RenderUniforms.h and of
// their Swift mirrors, with the same fields at the same offsets
// (WGSLLayoutTests). Metal's float3 and Swift's SIMD3 take 16 bytes, so a
// vec3f here takes @size(16), or the field after it moves. Only what a
// ported shader reads is here so far.

/// Mirror of CameraUniform.swift.
struct Camera {
    matrix: mat4x4f,
    @size(16) eye: vec3f,
    _padding: f32,
}

/// Mirror of GlobeUniform.swift.
struct Globe {
    panX: f32,
    panY: f32,
    radius: f32,
    transition: f32,
}

/// Per-frame derivatives of Globe, computed once on the CPU instead of once
/// per vertex. Mirrors GlobeFrameConstantsUniform.swift.
struct GlobeFrameConstants {
    /// The pan rotation, in the row-vector layout the vertex stages
    /// multiply with (`v * M`).
    rotation: mat4x4f,
    /// Unit earth direction straight to clip space: camera x translate x
    /// pan rotation x radius. Column-vector layout (`M * v`).
    sphereClip: mat4x4f,
    /// Unit earth direction to the world-space sphere position: translate x
    /// pan rotation x radius. Column-vector layout.
    sphereWorld: mat4x4f,
    mapSize: f32,
    panMercatorY: f32,
    panLatitude: f32,
    panLongitude: f32,
    /// The unroll curvature (1 - transition) / radius: 0 is the plane.
    curvature: f32,
    @size(16) _padding: vec3f,
}
