// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The matrix types of the stand-in (see Vector.swift). Column-major, as
// Apple's: `columns.0` is the first column, and a matrix times a vector takes
// the vector as a column.

/// Four columns of four floats. 64 bytes aligned to 16, the layout of
/// Apple's `simd_float4x4` and of a `float4x4` in a shader.
@frozen
public struct simd_float4x4: Equatable, Sendable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    /// The zero matrix.
    @inlinable
    public init() {
        columns = (.zero, .zero, .zero, .zero)
    }

    @inlinable
    public init(columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)) {
        self.columns = columns
    }

    @inlinable
    public init(_ col0: SIMD4<Float>, _ col1: SIMD4<Float>, _ col2: SIMD4<Float>, _ col3: SIMD4<Float>) {
        columns = (col0, col1, col2, col3)
    }

    @inlinable
    public init(_ columns: [SIMD4<Float>]) {
        precondition(columns.count == 4, "a 4x4 matrix takes four columns")
        self.columns = (columns[0], columns[1], columns[2], columns[3])
    }

    @inlinable
    public init(rows: [SIMD4<Float>]) {
        precondition(rows.count == 4, "a 4x4 matrix takes four rows")
        self = simd_float4x4(rows[0], rows[1], rows[2], rows[3]).transpose
    }

    @inlinable
    public init(diagonal: SIMD4<Float>) {
        columns = (SIMD4(diagonal.x, 0, 0, 0),
                   SIMD4(0, diagonal.y, 0, 0),
                   SIMD4(0, 0, diagonal.z, 0),
                   SIMD4(0, 0, 0, diagonal.w))
    }

    /// The scalar on the diagonal, zero elsewhere.
    @inlinable
    public init(_ scalar: Float) {
        self.init(diagonal: SIMD4(repeating: scalar))
    }

    /// The rotation a unit quaternion stands for.
    @inlinable
    public init(_ q: simd_quatf) {
        let r = simd_float3x3(q)
        columns = (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, 0, 0, 1))
    }

    @inlinable
    public subscript(column: Int) -> SIMD4<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            case 3: return columns.3
            default: preconditionFailure("column index out of range")
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            case 3: columns.3 = newValue
            default: preconditionFailure("column index out of range")
            }
        }
    }

    @inlinable
    public subscript(column: Int, row: Int) -> Float {
        get { self[column][row] }
        set { self[column][row] = newValue }
    }

    @inlinable
    public var transpose: simd_float4x4 {
        simd_float4x4(SIMD4(columns.0.x, columns.1.x, columns.2.x, columns.3.x),
                      SIMD4(columns.0.y, columns.1.y, columns.2.y, columns.3.y),
                      SIMD4(columns.0.z, columns.1.z, columns.2.z, columns.3.z),
                      SIMD4(columns.0.w, columns.1.w, columns.2.w, columns.3.w))
    }

    public var determinant: Float {
        let (adjugate, determinant) = adjugateAndDeterminant
        _ = adjugate
        return determinant
    }

    /// The inverse by cofactors. A singular matrix gives non-finite entries,
    /// as Apple's does.
    public var inverse: simd_float4x4 {
        let (adjugate, determinant) = adjugateAndDeterminant
        return adjugate * (1 / determinant)
    }

    @usableFromInline
    var adjugateAndDeterminant: (simd_float4x4, Float) {
        // Entries by row and column: m<row><column>.
        let m00 = columns.0.x, m10 = columns.0.y, m20 = columns.0.z, m30 = columns.0.w
        let m01 = columns.1.x, m11 = columns.1.y, m21 = columns.1.z, m31 = columns.1.w
        let m02 = columns.2.x, m12 = columns.2.y, m22 = columns.2.z, m32 = columns.2.w
        let m03 = columns.3.x, m13 = columns.3.y, m23 = columns.3.z, m33 = columns.3.w

        // The 2x2 minors of the lower and the upper pair of rows.
        let s0 = m00 * m11 - m10 * m01
        let s1 = m00 * m12 - m10 * m02
        let s2 = m00 * m13 - m10 * m03
        let s3 = m01 * m12 - m11 * m02
        let s4 = m01 * m13 - m11 * m03
        let s5 = m02 * m13 - m12 * m03
        let c5 = m22 * m33 - m32 * m23
        let c4 = m21 * m33 - m31 * m23
        let c3 = m21 * m32 - m31 * m22
        let c2 = m20 * m33 - m30 * m23
        let c1 = m20 * m32 - m30 * m22
        let c0 = m20 * m31 - m30 * m21

        let determinant = s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0

        let col0 = SIMD4<Float>(m11 * c5 - m12 * c4 + m13 * c3,
                                -m10 * c5 + m12 * c2 - m13 * c1,
                                m10 * c4 - m11 * c2 + m13 * c0,
                                -m10 * c3 + m11 * c1 - m12 * c0)
        let col1 = SIMD4<Float>(-m01 * c5 + m02 * c4 - m03 * c3,
                                m00 * c5 - m02 * c2 + m03 * c1,
                                -m00 * c4 + m01 * c2 - m03 * c0,
                                m00 * c3 - m01 * c1 + m02 * c0)
        let col2 = SIMD4<Float>(m31 * s5 - m32 * s4 + m33 * s3,
                                -m30 * s5 + m32 * s2 - m33 * s1,
                                m30 * s4 - m31 * s2 + m33 * s0,
                                -m30 * s3 + m31 * s1 - m32 * s0)
        let col3 = SIMD4<Float>(-m21 * s5 + m22 * s4 - m23 * s3,
                                m20 * s5 - m22 * s2 + m23 * s1,
                                -m20 * s4 + m21 * s2 - m23 * s0,
                                m20 * s3 - m21 * s1 + m22 * s0)
        return (simd_float4x4(col0, col1, col2, col3), determinant)
    }

    @inlinable
    public static func == (lhs: simd_float4x4, rhs: simd_float4x4) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1
            && lhs.columns.2 == rhs.columns.2 && lhs.columns.3 == rhs.columns.3
    }

    @inlinable
    public static func * (lhs: simd_float4x4, rhs: SIMD4<Float>) -> SIMD4<Float> {
        lhs.columns.0 * rhs.x + lhs.columns.1 * rhs.y + lhs.columns.2 * rhs.z + lhs.columns.3 * rhs.w
    }

    /// The vector as a row on the left.
    @inlinable
    public static func * (lhs: SIMD4<Float>, rhs: simd_float4x4) -> SIMD4<Float> {
        SIMD4(simd_dot(lhs, rhs.columns.0), simd_dot(lhs, rhs.columns.1),
              simd_dot(lhs, rhs.columns.2), simd_dot(lhs, rhs.columns.3))
    }

    @inlinable
    public static func * (lhs: simd_float4x4, rhs: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(lhs * rhs.columns.0, lhs * rhs.columns.1, lhs * rhs.columns.2, lhs * rhs.columns.3)
    }

    @inlinable
    public static func * (lhs: simd_float4x4, rhs: Float) -> simd_float4x4 {
        simd_float4x4(lhs.columns.0 * rhs, lhs.columns.1 * rhs, lhs.columns.2 * rhs, lhs.columns.3 * rhs)
    }

    @inlinable
    public static func * (lhs: Float, rhs: simd_float4x4) -> simd_float4x4 { rhs * lhs }

    @inlinable
    public static func *= (lhs: inout simd_float4x4, rhs: simd_float4x4) { lhs = lhs * rhs }

    @inlinable
    public static func + (lhs: simd_float4x4, rhs: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(lhs.columns.0 + rhs.columns.0, lhs.columns.1 + rhs.columns.1,
                      lhs.columns.2 + rhs.columns.2, lhs.columns.3 + rhs.columns.3)
    }

    @inlinable
    public static func - (lhs: simd_float4x4, rhs: simd_float4x4) -> simd_float4x4 {
        simd_float4x4(lhs.columns.0 - rhs.columns.0, lhs.columns.1 - rhs.columns.1,
                      lhs.columns.2 - rhs.columns.2, lhs.columns.3 - rhs.columns.3)
    }
}

/// Three columns of three floats. 48 bytes aligned to 16: each column takes
/// the room of four floats, as in Apple's `simd_float3x3` and in a shader.
@frozen
public struct simd_float3x3: Equatable, Sendable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    /// The zero matrix.
    @inlinable
    public init() {
        columns = (.zero, .zero, .zero)
    }

    @inlinable
    public init(columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)) {
        self.columns = columns
    }

    @inlinable
    public init(_ col0: SIMD3<Float>, _ col1: SIMD3<Float>, _ col2: SIMD3<Float>) {
        columns = (col0, col1, col2)
    }

    @inlinable
    public init(_ columns: [SIMD3<Float>]) {
        precondition(columns.count == 3, "a 3x3 matrix takes three columns")
        self.columns = (columns[0], columns[1], columns[2])
    }

    @inlinable
    public init(rows: [SIMD3<Float>]) {
        precondition(rows.count == 3, "a 3x3 matrix takes three rows")
        self = simd_float3x3(rows[0], rows[1], rows[2]).transpose
    }

    @inlinable
    public init(diagonal: SIMD3<Float>) {
        columns = (SIMD3(diagonal.x, 0, 0), SIMD3(0, diagonal.y, 0), SIMD3(0, 0, diagonal.z))
    }

    /// The scalar on the diagonal, zero elsewhere.
    @inlinable
    public init(_ scalar: Float) {
        self.init(diagonal: SIMD3(repeating: scalar))
    }

    /// The rotation a unit quaternion stands for.
    @inlinable
    public init(_ q: simd_quatf) {
        let x = q.vector.x, y = q.vector.y, z = q.vector.z, w = q.vector.w
        columns = (SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w)),
                   SIMD3(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w)),
                   SIMD3(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)))
    }

    @inlinable
    public subscript(column: Int) -> SIMD3<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: preconditionFailure("column index out of range")
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: preconditionFailure("column index out of range")
            }
        }
    }

    @inlinable
    public subscript(column: Int, row: Int) -> Float {
        get { self[column][row] }
        set { self[column][row] = newValue }
    }

    @inlinable
    public var transpose: simd_float3x3 {
        simd_float3x3(SIMD3(columns.0.x, columns.1.x, columns.2.x),
                      SIMD3(columns.0.y, columns.1.y, columns.2.y),
                      SIMD3(columns.0.z, columns.1.z, columns.2.z))
    }

    @inlinable
    public var determinant: Float {
        simd_dot(columns.0, simd_cross(columns.1, columns.2))
    }

    /// The inverse by cofactors. A singular matrix gives non-finite entries,
    /// as Apple's does.
    @inlinable
    public var inverse: simd_float3x3 {
        let r0 = simd_cross(columns.1, columns.2)
        let r1 = simd_cross(columns.2, columns.0)
        let r2 = simd_cross(columns.0, columns.1)
        let scale = 1 / simd_dot(columns.0, r0)
        return simd_float3x3(rows: [r0 * scale, r1 * scale, r2 * scale])
    }

    @inlinable
    public static func == (lhs: simd_float3x3, rhs: simd_float3x3) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1 && lhs.columns.2 == rhs.columns.2
    }

    @inlinable
    public static func * (lhs: simd_float3x3, rhs: SIMD3<Float>) -> SIMD3<Float> {
        lhs.columns.0 * rhs.x + lhs.columns.1 * rhs.y + lhs.columns.2 * rhs.z
    }

    /// The vector as a row on the left.
    @inlinable
    public static func * (lhs: SIMD3<Float>, rhs: simd_float3x3) -> SIMD3<Float> {
        SIMD3(simd_dot(lhs, rhs.columns.0), simd_dot(lhs, rhs.columns.1), simd_dot(lhs, rhs.columns.2))
    }

    @inlinable
    public static func * (lhs: simd_float3x3, rhs: simd_float3x3) -> simd_float3x3 {
        simd_float3x3(lhs * rhs.columns.0, lhs * rhs.columns.1, lhs * rhs.columns.2)
    }

    @inlinable
    public static func * (lhs: simd_float3x3, rhs: Float) -> simd_float3x3 {
        simd_float3x3(lhs.columns.0 * rhs, lhs.columns.1 * rhs, lhs.columns.2 * rhs)
    }

    @inlinable
    public static func * (lhs: Float, rhs: simd_float3x3) -> simd_float3x3 { rhs * lhs }
}

public typealias matrix_float4x4 = simd_float4x4
public typealias matrix_float3x3 = simd_float3x3
public typealias float4x4 = simd_float4x4
public typealias float3x3 = simd_float3x3

public let matrix_identity_float4x4 = simd_float4x4(1)
public let matrix_identity_float3x3 = simd_float3x3(1)

@inlinable public func simd_mul(_ x: simd_float4x4, _ y: simd_float4x4) -> simd_float4x4 { x * y }
@inlinable public func simd_mul(_ x: simd_float4x4, _ y: SIMD4<Float>) -> SIMD4<Float> { x * y }
@inlinable public func simd_mul(_ x: SIMD4<Float>, _ y: simd_float4x4) -> SIMD4<Float> { x * y }
@inlinable public func simd_mul(_ x: simd_float3x3, _ y: simd_float3x3) -> simd_float3x3 { x * y }
@inlinable public func simd_mul(_ x: simd_float3x3, _ y: SIMD3<Float>) -> SIMD3<Float> { x * y }
@inlinable public func simd_mul(_ x: SIMD3<Float>, _ y: simd_float3x3) -> SIMD3<Float> { x * y }
@inlinable public func matrix_multiply(_ x: simd_float4x4, _ y: simd_float4x4) -> simd_float4x4 { x * y }
@inlinable public func matrix_multiply(_ x: simd_float3x3, _ y: simd_float3x3) -> simd_float3x3 { x * y }
@inlinable public func simd_transpose(_ x: simd_float4x4) -> simd_float4x4 { x.transpose }
@inlinable public func simd_transpose(_ x: simd_float3x3) -> simd_float3x3 { x.transpose }
@inlinable public func simd_determinant(_ x: simd_float4x4) -> Float { x.determinant }
@inlinable public func simd_determinant(_ x: simd_float3x3) -> Float { x.determinant }
@inlinable public func simd_inverse(_ x: simd_float4x4) -> simd_float4x4 { x.inverse }
@inlinable public func simd_inverse(_ x: simd_float3x3) -> simd_float3x3 { x.inverse }
