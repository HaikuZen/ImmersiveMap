// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: GlobeTransitionProjection.h fnv1a64=e1c899cd32c91076
// include: ../../Render/Shaders/Shared/RenderUniforms.wgsl
// include: ../../Render/Shaders/Shared/GeoMath.wgsl

// The flat map the globe morphs into. WGSL has no overloads: each function
// is Metal's that takes the reference x, and a point with no neighbours
// passes its own x as the reference.

/// The flat x of a normalized world x, in the copy of the wrapped world
/// nearest the reference's, so a tile unwraps around its own centre and
/// never tears across the seam.
fn globeTransitionFlatWorldX(normalizedWorldX: f32, referenceNormalizedWorldX: f32, globe: Globe, mapSize: f32) -> f32 {
    let halfMapSize = mapSize * 0.5;
    let panOffset = globe.panX * halfMapSize - halfMapSize;
    let reference = wrap(referenceNormalizedWorldX * mapSize + panOffset, mapSize);
    let value = normalizedWorldX * mapSize + panOffset;
    return reference + wrap(value - reference, mapSize);
}

fn globeTransitionFlatWorldY(mercatorY: f32, panMercatorY: f32, mapSize: f32) -> f32 {
    let halfMapSize = mapSize * 0.5;
    return (mercatorY - panMercatorY) * halfMapSize;
}

fn globeTransitionFlatWorldPosition(normalizedWorldX: f32,
                                    mercatorY: f32,
                                    globe: Globe,
                                    mapSize: f32,
                                    panMercatorY: f32,
                                    referenceNormalizedWorldX: f32) -> vec2f {
    return vec2f(globeTransitionFlatWorldX(normalizedWorldX, referenceNormalizedWorldX, globe, mapSize),
                 globeTransitionFlatWorldY(mercatorY, panMercatorY, mapSize));
}
