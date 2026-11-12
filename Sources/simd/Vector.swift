// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// A stand-in for Apple's `simd` module on the platforms that have none.
//
// The engine writes `import simd` everywhere and means Apple's module, which
// exists only in Apple's SDKs. Outside them Package.swift declares this target
// under the same name, so the same sources compile against it unchanged. It
// is never declared on Apple's platforms, where the real module is used.
//
// It holds only what the engine uses, written over the standard library's
// `SIMD2`, `SIMD3` and `SIMD4`, which are the same types Apple's module
// works on. A function the engine starts to use is added here under the name
// and with the meaning Apple gives it. The memory layout of the matrix and
// quaternion types matches Apple's, since the engine hands them to shaders.

// Apple's module brings the C math functions with it, and files that import
// nothing else rely on that.
#if canImport(Glibc)
@_exported import Glibc
#elseif canImport(Musl)
@_exported import Musl
#elseif canImport(WASILibc)
@_exported import WASILibc
#elseif canImport(Android)
@_exported import Android
#elseif canImport(ucrt)
@_exported import ucrt
#endif

public typealias simd_float1 = Float
public typealias simd_double1 = Double
public typealias simd_int1 = Int32
public typealias simd_uint1 = UInt32
public typealias simd_float2 = SIMD2<Float>
public typealias simd_float3 = SIMD3<Float>
public typealias simd_float4 = SIMD4<Float>
public typealias simd_double2 = SIMD2<Double>
public typealias simd_double3 = SIMD3<Double>
public typealias simd_double4 = SIMD4<Double>

// MARK: - Products and lengths

@inlinable
public func simd_dot<V: SIMD>(_ x: V, _ y: V) -> V.Scalar where V.Scalar: FloatingPoint {
    (x * y).sum()
}

@inlinable
public func simd_length_squared<V: SIMD>(_ x: V) -> V.Scalar where V.Scalar: FloatingPoint {
    (x * x).sum()
}

@inlinable
public func simd_length<V: SIMD>(_ x: V) -> V.Scalar where V.Scalar: FloatingPoint {
    (x * x).sum().squareRoot()
}

@inlinable
public func simd_distance_squared<V: SIMD>(_ x: V, _ y: V) -> V.Scalar where V.Scalar: FloatingPoint {
    simd_length_squared(x - y)
}

@inlinable
public func simd_distance<V: SIMD>(_ x: V, _ y: V) -> V.Scalar where V.Scalar: FloatingPoint {
    simd_length(x - y)
}

/// The vector scaled to length one. A zero vector has no direction and gives
/// NaN components, as Apple's does.
@inlinable
public func simd_normalize<V: SIMD>(_ x: V) -> V where V.Scalar: FloatingPoint {
    x / simd_length(x)
}

@inlinable
public func simd_cross<T: SIMDScalar & FloatingPoint>(_ x: SIMD3<T>, _ y: SIMD3<T>) -> SIMD3<T> {
    SIMD3(x.y * y.z - x.z * y.y,
          x.z * y.x - x.x * y.z,
          x.x * y.y - x.y * y.x)
}

/// The cross product of two vectors of the plane, which points along z.
@inlinable
public func simd_cross<T: SIMDScalar & FloatingPoint>(_ x: SIMD2<T>, _ y: SIMD2<T>) -> SIMD3<T> {
    SIMD3(0, 0, x.x * y.y - x.y * y.x)
}

// MARK: - Componentwise

@inlinable
public func simd_min<V: SIMD>(_ x: V, _ y: V) -> V where V.Scalar: Comparable {
    pointwiseMin(x, y)
}

@inlinable
public func simd_max<V: SIMD>(_ x: V, _ y: V) -> V where V.Scalar: Comparable {
    pointwiseMax(x, y)
}

@inlinable
public func simd_min<T: BinaryFloatingPoint>(_ x: T, _ y: T) -> T { Swift.min(x, y) }

@inlinable
public func simd_max<T: BinaryFloatingPoint>(_ x: T, _ y: T) -> T { Swift.max(x, y) }

@inlinable
public func simd_abs<V: SIMD>(_ x: V) -> V where V.Scalar: FloatingPoint {
    x.replacing(with: -x, where: x .< V.zero)
}

@inlinable
public func simd_abs<V: SIMD>(_ x: V) -> V where V.Scalar: FixedWidthInteger & SignedInteger {
    x.replacing(with: V.zero &- x, where: x .< V.zero)
}

@inlinable
public func simd_clamp<V: SIMD>(_ x: V, _ min: V, _ max: V) -> V where V.Scalar: Comparable {
    pointwiseMin(pointwiseMax(x, min), max)
}

@inlinable
public func simd_clamp<V: SIMD>(_ x: V, _ min: V.Scalar, _ max: V.Scalar) -> V where V.Scalar: Comparable {
    pointwiseMin(pointwiseMax(x, V(repeating: min)), V(repeating: max))
}

@inlinable
public func simd_clamp<T: BinaryFloatingPoint>(_ x: T, _ min: T, _ max: T) -> T {
    Swift.min(Swift.max(x, min), max)
}

/// `x` at `t` zero, `y` at `t` one, a straight line between and beyond.
@inlinable
public func simd_mix<V: SIMD>(_ x: V, _ y: V, _ t: V) -> V where V.Scalar: FloatingPoint {
    x + t * (y - x)
}

@inlinable
public func simd_mix<V: SIMD>(_ x: V, _ y: V, _ t: V.Scalar) -> V where V.Scalar: FloatingPoint {
    x + (y - x) * t
}

@inlinable
public func simd_mix<T: BinaryFloatingPoint>(_ x: T, _ y: T, _ t: T) -> T {
    x + t * (y - x)
}

/// Zero up to `edge0`, one from `edge1`, the cubic 3t² - 2t³ between.
@inlinable
public func simd_smoothstep<T: BinaryFloatingPoint>(_ edge0: T, _ edge1: T, _ x: T) -> T {
    let t = simd_clamp((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

@inlinable
public func simd_smoothstep<V: SIMD>(_ edge0: V, _ edge1: V, _ x: V) -> V where V.Scalar: BinaryFloatingPoint {
    let t = simd_clamp((x - edge0) / (edge1 - edge0), V.zero, V.one)
    return t * t * (V(repeating: 3) - t * 2)
}

// MARK: - The same under the short names

@inlinable public func dot<V: SIMD>(_ x: V, _ y: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_dot(x, y) }
@inlinable public func length<V: SIMD>(_ x: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length(x) }
@inlinable public func length_squared<V: SIMD>(_ x: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_length_squared(x) }
@inlinable public func distance<V: SIMD>(_ x: V, _ y: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_distance(x, y) }
@inlinable public func distance_squared<V: SIMD>(_ x: V, _ y: V) -> V.Scalar where V.Scalar: FloatingPoint { simd_distance_squared(x, y) }
@inlinable public func normalize<V: SIMD>(_ x: V) -> V where V.Scalar: FloatingPoint { simd_normalize(x) }
@inlinable public func cross<T: SIMDScalar & FloatingPoint>(_ x: SIMD3<T>, _ y: SIMD3<T>) -> SIMD3<T> { simd_cross(x, y) }
@inlinable public func cross<T: SIMDScalar & FloatingPoint>(_ x: SIMD2<T>, _ y: SIMD2<T>) -> SIMD3<T> { simd_cross(x, y) }
@inlinable public func min<V: SIMD>(_ x: V, _ y: V) -> V where V.Scalar: Comparable { pointwiseMin(x, y) }
@inlinable public func max<V: SIMD>(_ x: V, _ y: V) -> V where V.Scalar: Comparable { pointwiseMax(x, y) }
@inlinable public func abs<V: SIMD>(_ x: V) -> V where V.Scalar: FloatingPoint { simd_abs(x) }
@inlinable public func clamp<V: SIMD>(_ x: V, min: V, max: V) -> V where V.Scalar: Comparable { simd_clamp(x, min, max) }
@inlinable public func clamp<V: SIMD>(_ x: V, min: V.Scalar, max: V.Scalar) -> V where V.Scalar: Comparable { simd_clamp(x, min, max) }
@inlinable public func mix<V: SIMD>(_ x: V, _ y: V, t: V) -> V where V.Scalar: FloatingPoint { simd_mix(x, y, t) }
@inlinable public func mix<V: SIMD>(_ x: V, _ y: V, t: V.Scalar) -> V where V.Scalar: FloatingPoint { simd_mix(x, y, t) }
@inlinable public func smoothstep<V: SIMD>(_ x: V, edge0: V, edge1: V) -> V where V.Scalar: BinaryFloatingPoint { simd_smoothstep(edge0, edge1, x) }
