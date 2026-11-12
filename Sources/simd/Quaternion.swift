// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The quaternion of the stand-in (see Vector.swift).

/// A quaternion of floats, the imaginary part in `vector.xyz` and the real
/// part in `vector.w`, the layout of Apple's `simd_quatf`.
@frozen
public struct simd_quatf: Equatable, Sendable {
    public var vector: SIMD4<Float>

    /// The zero quaternion, which is no rotation: the identity is
    /// `simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)`.
    @inlinable
    public init() {
        vector = .zero
    }

    @inlinable
    public init(vector: SIMD4<Float>) {
        self.vector = vector
    }

    @inlinable
    public init(ix: Float, iy: Float, iz: Float, r: Float) {
        vector = SIMD4(ix, iy, iz, r)
    }

    @inlinable
    public init(real: Float, imag: SIMD3<Float>) {
        vector = SIMD4(imag, real)
    }

    /// The rotation by `angle` radians about `axis`, which is taken as given:
    /// a unit axis makes a unit quaternion.
    @inlinable
    public init(angle: Float, axis: SIMD3<Float>) {
        let half = angle / 2
        vector = SIMD4(axis * sin(half), cos(half))
    }

    @inlinable public var real: Float {
        get { vector.w }
        set { vector.w = newValue }
    }

    @inlinable public var imag: SIMD3<Float> {
        get { SIMD3(vector.x, vector.y, vector.z) }
        set { vector = SIMD4(newValue, vector.w) }
    }

    /// The angle of the rotation in radians, from zero to 2π.
    @inlinable public var angle: Float {
        2 * atan2(simd_length(imag), real)
    }

    @inlinable public var axis: SIMD3<Float> {
        simd_normalize(imag)
    }

    @inlinable public var conjugate: simd_quatf {
        simd_quatf(real: real, imag: -imag)
    }

    @inlinable public var inverse: simd_quatf {
        simd_quatf(vector: conjugate.vector / simd_length_squared(vector))
    }

    @inlinable public var length: Float {
        simd_length(vector)
    }

    @inlinable public var normalized: simd_quatf {
        simd_quatf(vector: simd_normalize(vector))
    }

    /// The vector turned by the quaternion, which must be of unit length.
    @inlinable
    public func act(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let t = simd_cross(imag, v) * 2
        return v + t * real + simd_cross(imag, t)
    }

    /// The product: the rotation `rhs` followed by the rotation `lhs`.
    @inlinable
    public static func * (lhs: simd_quatf, rhs: simd_quatf) -> simd_quatf {
        let a = lhs.imag, b = rhs.imag
        return simd_quatf(real: lhs.real * rhs.real - simd_dot(a, b),
                          imag: b * lhs.real + a * rhs.real + simd_cross(a, b))
    }

    @inlinable
    public static func *= (lhs: inout simd_quatf, rhs: simd_quatf) { lhs = lhs * rhs }

    @inlinable
    public static func * (lhs: simd_quatf, rhs: Float) -> simd_quatf { simd_quatf(vector: lhs.vector * rhs) }

    @inlinable
    public static func + (lhs: simd_quatf, rhs: simd_quatf) -> simd_quatf { simd_quatf(vector: lhs.vector + rhs.vector) }

    @inlinable
    public static prefix func - (q: simd_quatf) -> simd_quatf { simd_quatf(vector: -q.vector) }
}

@inlinable public func simd_act(_ q: simd_quatf, _ v: SIMD3<Float>) -> SIMD3<Float> { q.act(v) }
@inlinable public func simd_mul(_ p: simd_quatf, _ q: simd_quatf) -> simd_quatf { p * q }
@inlinable public func simd_normalize(_ q: simd_quatf) -> simd_quatf { q.normalized }
@inlinable public func simd_inverse(_ q: simd_quatf) -> simd_quatf { q.inverse }
@inlinable public func simd_conjugate(_ q: simd_quatf) -> simd_quatf { q.conjugate }
@inlinable public func simd_length(_ q: simd_quatf) -> Float { q.length }
@inlinable public func simd_dot(_ p: simd_quatf, _ q: simd_quatf) -> Float { simd_dot(p.vector, q.vector) }
@inlinable public func simd_angle(_ q: simd_quatf) -> Float { q.angle }
@inlinable public func simd_axis(_ q: simd_quatf) -> SIMD3<Float> { q.axis }

/// The rotation a fraction `t` of the way from `q0` to `q1` along the shorter
/// arc, at constant angular speed. Both must be of unit length.
public func simd_slerp(_ q0: simd_quatf, _ q1: simd_quatf, _ t: Float) -> simd_quatf {
    var cosine = simd_dot(q0.vector, q1.vector)
    var end = q1.vector
    // q and -q are the same rotation: take the one on q0's side.
    if cosine < 0 {
        cosine = -cosine
        end = -end
    }
    // Nearly the same rotation: the arc is a straight line to within rounding,
    // and the general formula would divide by a sine near zero.
    if cosine > 0.9995 {
        return simd_quatf(vector: simd_normalize(q0.vector + (end - q0.vector) * t))
    }
    let angle = acos(cosine)
    let sine = sin(angle)
    let w0 = sin((1 - t) * angle) / sine
    let w1 = sin(t * angle) / sine
    return simd_quatf(vector: q0.vector * w0 + end * w1)
}
