// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

// ported-from: GlobeTileProjection.h fnv1a64=e59597b1205b09e6
// include: ../../Render/Shaders/Shared/GeoMath.wgsl

// The globe's projections of world and tile uvs. Only what a ported shader
// reads is here so far.

/// The unit earth-fixed direction of a world uv, straight from the Mercator
/// row through the Gudermannian identities (sin lat = tanh x, cos lat =
/// sech x for x = pi (1 - 2 v)), the latitude angle never computed.
fn globeWorldUVUnitDirection(worldUv: vec2f) -> vec3f {
    let x = kPi * (1.0 - 2.0 * worldUv.y);
    let e = exp(x);
    let inverseE = 1.0 / e;
    let sinLatitude = (e - inverseE) / (e + inverseE);
    let cosLatitude = 2.0 / (e + inverseE);
    let longitude = worldUv.x * (2.0 * kPi) - kPi;
    return vec3f(cosLatitude * sin(longitude), sinLatitude, cosLatitude * cos(longitude));
}
