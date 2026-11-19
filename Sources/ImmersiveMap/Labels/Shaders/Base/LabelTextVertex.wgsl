// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: LabelTextVertex.metal fnv1a64=ead21cc7596eaceb
// include: ../Shared/LabelTextCommon.wgsl

// The screen labels' vertex stage: each glyph of a label hung off the
// label's screen point.

@group(0) @binding(1) var<uniform> matrix: mat4x4f;
@group(0) @binding(2) var<storage, read> screenPositions: array<ScreenPointOutput>;
@group(0) @binding(3) var<uniform> globalTextShift: i32;
@group(0) @binding(6) var<storage, read> labelMeta: array<LabelRuntimeMeta>;
@group(0) @binding(7) var<uniform> pixelsPerPoint: f32;

@vertex
fn labelTextVertex(vertexIn: LabelVertexIn) -> VertexOut {
    let screenIndex = vertexIn.labelIndex + globalTextShift;
    return labelQuadVertex(vertexIn, matrix, screenPositions[screenIndex], labelMeta[screenIndex], pixelsPerPoint);
}
