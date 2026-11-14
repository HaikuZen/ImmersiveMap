// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// ported-from: GlobeUnroll.h fnv1a64=eafa21078a72d586

// The sphere-to-plane unroll: the surface lives on a sphere of radius
// 1 / curvature tangent to the view centre, and every point travels a
// straight line in the chart between its azimuthal-equidistant image and
// its Mercator position. A point is cut while its remaining travel is
// long. GlobeUnroll.h explains it, and GlobeUnrollMath.swift mirrors it.

/// The unroll's cut, as a fraction of the planet radius. Mirrored by
/// GlobeUnrollMath.cutTravelFraction.
const kGlobeUnrollCutTravel = 0.25;

/// The azimuthal-equidistant image of a sphere position about the view
/// centre: arc times departure bearing.
fn globeUnrollChartAE(sphereWorldPosition: vec3f, radius: f32) -> vec2f {
    let fromCenter = sphereWorldPosition - vec3f(0.0, 0.0, -radius);
    let cosTheta = clamp(fromCenter.z / max(radius, 1e-6), -1.0, 1.0);
    let arcSphere = radius * acos(cosTheta);
    let dirSphere = fromCenter.xy;
    let dirSphereLength = length(dirSphere);
    if (dirSphereLength > 1e-6) {
        return dirSphere * (arcSphere / dirSphereLength);
    }
    return vec2f(0.0);
}

/// The cut clearance a morph vertex stage clips by: positive once the
/// vertex's remaining chart travel is short enough to show.
fn globeUnrollCutClearance(sphereWorldPosition: vec3f, flatWorldPosition: vec2f, transition: f32, radius: f32) -> f32 {
    let chartAE = globeUnrollChartAE(sphereWorldPosition, radius);
    let remaining = (1.0 - transition) * length(flatWorldPosition - chartAE);
    return kGlobeUnrollCutTravel - remaining / max(radius, 1e-6);
}

fn globeUnrollWorldPosition(sphereWorldPosition: vec3f, flatWorldPosition: vec2f, transition: f32, radius: f32) -> vec3f {
    let curvature = (1.0 - transition) / max(radius, 1e-6);
    if (curvature <= 1e-9) {
        return vec3f(flatWorldPosition, 0.0);
    }
    // The straight chart line between the two flat images of the point.
    let chartPoint = mix(globeUnrollChartAE(sphereWorldPosition, radius), flatWorldPosition, transition);
    let arc = length(chartPoint);
    if (arc <= 1e-6) {
        return vec3f(chartPoint, 0.0);
    }
    let azimuth = chartPoint / arc;
    let angle = arc * curvature;
    let rho = sin(angle) / curvature;
    let sag = (cos(angle) - 1.0) / curvature;
    return vec3f(azimuth * rho, sag);
}
