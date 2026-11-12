// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd
import XCTest

/// The functions the engine takes from `simd`, held to answers worked out by
/// hand. The module under test is Apple's on Apple's platforms and the
/// package's stand-in elsewhere, so a difference between the two shows up as
/// a failure on one side.
final class SimdKnownAnswerTests: XCTestCase {
    private let accuracy: Float = 1e-5

    // MARK: - Layout

    func testTheMatrixAndQuaternionLayoutsAreTheShadersLayouts() {
        XCTAssertEqual(MemoryLayout<simd_float4x4>.size, 64)
        XCTAssertEqual(MemoryLayout<simd_float4x4>.stride, 64)
        XCTAssertEqual(MemoryLayout<simd_float4x4>.alignment, 16)
        XCTAssertEqual(MemoryLayout<simd_float3x3>.size, 48)
        XCTAssertEqual(MemoryLayout<simd_float3x3>.stride, 48)
        XCTAssertEqual(MemoryLayout<simd_float3x3>.alignment, 16)
        XCTAssertEqual(MemoryLayout<simd_quatf>.size, 16)
        XCTAssertEqual(MemoryLayout<simd_quatf>.alignment, 16)
        XCTAssertEqual(MemoryLayout<simd_int1>.size, 4)
        XCTAssertEqual(MemoryLayout<simd_float1>.size, 4)
    }

    func testAMatrixIsStoredColumnByColumn() {
        var matrix = simd_float4x4(SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8),
                                   SIMD4<Float>(9, 10, 11, 12), SIMD4<Float>(13, 14, 15, 16))
        let floats = withUnsafeBytes(of: &matrix) { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(floats, (1...16).map(Float.init))
    }

    // MARK: - Vectors

    func testProductsAndLengths() {
        let a = SIMD3<Float>(1, 2, 3), b = SIMD3<Float>(4, -5, 6)
        XCTAssertEqual(simd_dot(a, b), 12)
        XCTAssertEqual(simd_cross(a, b), SIMD3<Float>(27, 6, -13))
        XCTAssertEqual(simd_length(SIMD2<Float>(3, 4)), 5)
        XCTAssertEqual(simd_length_squared(SIMD2<Float>(3, 4)), 25)
        XCTAssertEqual(simd_distance(SIMD2<Double>(1, 1), SIMD2<Double>(4, 5)), 5)
        XCTAssertEqual(simd_distance_squared(SIMD2<Double>(1, 1), SIMD2<Double>(4, 5)), 25)
        XCTAssertLessThan(simd_distance(simd_normalize(SIMD3<Double>(0, 3, 4)), SIMD3<Double>(0, 0.6, 0.8)), 1e-12)
        XCTAssertEqual(simd_length(SIMD4<Double>(2, 2, 2, 2)), 4)
    }

    func testComponentwiseFunctions() {
        let a = SIMD3<Float>(1, -2, 3), b = SIMD3<Float>(0, 5, 3)
        XCTAssertEqual(simd_min(a, b), SIMD3<Float>(0, -2, 3))
        XCTAssertEqual(simd_max(a, b), SIMD3<Float>(1, 5, 3))
        XCTAssertEqual(simd_abs(a), SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(simd_clamp(a, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 2)), SIMD3<Float>(1, 0, 2))
        XCTAssertEqual(simd_clamp(Float(7), 0, 2), 2)
        XCTAssertEqual(simd_clamp(Float(-7), 0, 2), 0)
        XCTAssertEqual(simd_mix(SIMD2<Float>(0, 10), SIMD2<Float>(4, 20), SIMD2<Float>(0.25, 0.5)), SIMD2<Float>(1, 15))
        XCTAssertEqual(simd_mix(Float(2), 6, 0.5), 4)
        XCTAssertEqual(simd_smoothstep(Float(0), 2, -1), 0)
        XCTAssertEqual(simd_smoothstep(Float(0), 2, 1), 0.5)
        XCTAssertEqual(simd_smoothstep(Float(0), 2, 0.5), 0.15625)
        XCTAssertEqual(simd_smoothstep(Float(0), 2, 3), 1)
    }

    // MARK: - Matrices

    private func translationScale() -> simd_float4x4 {
        // Scales by (2, 4, 8), then moves by (1, 2, 3).
        simd_float4x4(columns: (SIMD4<Float>(2, 0, 0, 0), SIMD4<Float>(0, 4, 0, 0),
                                SIMD4<Float>(0, 0, 8, 0), SIMD4<Float>(1, 2, 3, 1)))
    }

    func testAMatrixTakesAVectorAsAColumn() {
        XCTAssertEqual(translationScale() * SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(3, 6, 11, 1))
        XCTAssertEqual(simd_mul(translationScale(), SIMD4<Float>(1, 1, 1, 1)), SIMD4<Float>(3, 6, 11, 1))
        // A vector on the left is a row.
        XCTAssertEqual(SIMD4<Float>(1, 1, 1, 1) * translationScale(), SIMD4<Float>(2, 4, 8, 7))
    }

    func testAProductAppliesTheRightHandMatrixFirst() {
        let move = simd_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                           SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(10, 0, 0, 1)))
        let scale = simd_float4x4(diagonal: SIMD4<Float>(2, 2, 2, 1))
        let point = SIMD4<Float>(1, 0, 0, 1)
        XCTAssertEqual((move * scale) * point, SIMD4<Float>(12, 0, 0, 1))
        XCTAssertEqual((scale * move) * point, SIMD4<Float>(22, 0, 0, 1))
        XCTAssertEqual(simd_mul(move, scale), move * scale)
        XCTAssertEqual(matrix_multiply(move, scale), move * scale)
    }

    func testIdentityDiagonalAndTranspose() {
        XCTAssertEqual(matrix_identity_float4x4, simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1)))
        XCTAssertEqual(matrix_identity_float4x4 * translationScale(), translationScale())
        let transposed = simd_transpose(translationScale())
        XCTAssertEqual(transposed.columns.0, SIMD4<Float>(2, 0, 0, 1))
        XCTAssertEqual(transposed.columns.3, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(translationScale().transpose, transposed)
        XCTAssertEqual(matrix_float4x4(columns: translationScale().columns), translationScale())
    }

    func testTheInverseUndoesTheMatrix() {
        let inverse = simd_inverse(translationScale())
        XCTAssertEqual(inverse.columns.0, SIMD4<Float>(0.5, 0, 0, 0))
        XCTAssertEqual(inverse.columns.1, SIMD4<Float>(0, 0.25, 0, 0))
        XCTAssertEqual(inverse.columns.2, SIMD4<Float>(0, 0, 0.125, 0))
        XCTAssertEqual(inverse.columns.3, SIMD4<Float>(-0.5, -0.5, -0.375, 1))
        XCTAssertEqual(translationScale().inverse, inverse)

        // A matrix with no zero entry and no structure to hide a wrong cofactor.
        let dense = simd_float4x4(SIMD4<Float>(4, 7, 2, 3), SIMD4<Float>(0, 5, 0, 1),
                                  SIMD4<Float>(1, 0, 3, 0), SIMD4<Float>(2, 6, 1, 8))
        let product = dense * simd_inverse(dense)
        for column in 0..<4 {
            for row in 0..<4 {
                XCTAssertEqual(product[column][row], column == row ? 1 : 0, accuracy: accuracy)
            }
        }

        let small = simd_float3x3(SIMD3<Float>(2, 0, 0), SIMD3<Float>(1, 4, 0), SIMD3<Float>(0, 3, 5))
        let smallProduct = small * simd_inverse(small)
        for column in 0..<3 {
            for row in 0..<3 {
                XCTAssertEqual(smallProduct[column][row], column == row ? 1 : 0, accuracy: accuracy)
            }
        }
    }

    // MARK: - Quaternions

    func testAQuaternionTurnsCounterclockwiseAboutItsAxis() {
        let quarterAboutZ = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        assertEqual(simd_act(quarterAboutZ, SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 1, 0))
        assertEqual(quarterAboutZ.act(SIMD3<Float>(0, 1, 0)), SIMD3<Float>(-1, 0, 0))
        XCTAssertEqual(quarterAboutZ.angle, .pi / 2, accuracy: accuracy)
        XCTAssertEqual(quarterAboutZ.vector.w, cos(Float.pi / 4), accuracy: accuracy)
        XCTAssertEqual(quarterAboutZ.vector.z, sin(Float.pi / 4), accuracy: accuracy)
    }

    func testAQuaternionProductAppliesTheRightHandRotationFirst() {
        let aboutZ = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        let aboutX = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        // x goes to y about z, and y goes to z about x.
        assertEqual(simd_act(aboutX * aboutZ, SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 0, 1))
        // x stays about x, and goes to y about z.
        assertEqual(simd_act(aboutZ * aboutX, SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 1, 0))
    }

    func testAQuaternionsMatrixTurnsAsTheQuaternionDoes() {
        let rotation = simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        let vector = SIMD3<Float>(0.3, -1.2, 2.5)
        let turned = simd_act(rotation, vector)
        let byMatrix = simd_float4x4(rotation) * SIMD4<Float>(vector, 1)
        assertEqual(SIMD3<Float>(byMatrix.x, byMatrix.y, byMatrix.z), turned)
        XCTAssertEqual(byMatrix.w, 1)
        assertEqual(simd_float3x3(rotation) * vector, turned)
    }

    func testSlerpGoesTheShorterWayAtConstantSpeed() {
        let start = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
        let end = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(simd_slerp(start, end, 0.5).angle, .pi / 4, accuracy: accuracy)
        XCTAssertEqual(simd_slerp(start, end, 0.25).angle, .pi / 8, accuracy: accuracy)
        assertEqual(simd_act(simd_slerp(start, end, 1), SIMD3<Float>(1, 0, 0)), SIMD3<Float>(0, 1, 0))
        // The negated end is the same rotation, and the way to it is the same.
        let negatedEnd = simd_quatf(vector: -end.vector)
        assertEqual(simd_act(simd_slerp(start, negatedEnd, 0.5), SIMD3<Float>(1, 0, 0)),
                    SIMD3<Float>(cos(.pi / 4), sin(.pi / 4), 0))
        XCTAssertLessThan(simd_distance(simd_quatf(vector: SIMD4<Float>(0, 0, 3, 4)).normalized.vector,
                                        SIMD4<Float>(0, 0, 0.6, 0.8)), accuracy)
    }

    private func assertEqual(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(actual, expected), accuracy,
                          "\(actual) is not \(expected)", file: file, line: line)
    }
}
