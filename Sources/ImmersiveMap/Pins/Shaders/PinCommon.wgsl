// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: PinCommon.h fnv1a64=f02ef2f676ef820d
// ported-from: ../../Render/Shaders/Screen/ScreenCommon.h fnv1a64=62c472a0a6bf364b

// The pins' GPU values, each at its Swift twin's offsets (PinTypes.swift,
// held by WGSLLayoutTests).

/// Mirrors ScreenPointOutput.swift.
struct ScreenPointOutput {
    position: vec2f,
    depth: f32,
    visible: u32,
    visibilityAlpha: f32,
}

struct PinInstanceGPU {
    uvRect: vec4f,
    borderColor: vec4f,
    squashScale: vec2f,
    atlasIndex: u32,
    flags: u32,
    morph: f32,
    _pad0: f32,
    _pad1: vec2f,
}

struct PinCountBadgeInstanceGPU {
    uvRect: vec4f,
    flags: u32,
    screenSizeScale: f32,
    contentAlpha: f32,
    _padding: f32,
}

struct PinOffset {
    value: vec2f,
    scale: f32,
    _padding: f32,
}

struct PinBeamStyleGPU {
    pinCenterOffsetPx: vec2f,
    pinBodyHalfMinPx: f32,
    _padding: f32,
}

/// Mirrors PinStyleGPU in PinTypes.swift. The fractions are of the pin's
/// quad, origin in the bottom left corner, y up.
struct PinStyleGPU {
    sizePx: vec2f,
    anchorUv: vec2f,
    bodyCenterUv: vec2f,
    bodyHalfUv: vec2f,
    circleRadiusUv: f32,
    outlineWidthPx: f32,
    contentInsetPx: f32,
    distanceRangeTexels: f32,
    fillColor: vec4f,
    frameless: u32,
    distanceInAlpha: u32,
    _pad1: vec2f,
}

struct PinCountBadgeStyleGPU {
    sizePx: vec2f,
    originXPx: f32,
    originYPx: f32,
}

/// The two triangles of a pin's quad, in the quad's own coordinates.
fn pinQuadCorner(vertexIndex: u32) -> vec2f {
    var quad = array<vec2f, 6>(
        vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(0.0, 1.0),
        vec2f(0.0, 1.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0)
    );
    return quad[vertexIndex];
}
