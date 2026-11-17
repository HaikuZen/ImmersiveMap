// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import simd

struct CameraUniform {
    let matrix: matrix_float4x4
    let eye: SIMD3<Float>
    let padding: Float
    /// The gap to the stride, which the matrix aligns to 16, named: Swift would leave its bytes as whatever
    /// the stack held, and they would go to the GPU with the constant data.
    let _gap0: Float = 0, _gap1: Float = 0, _gap2: Float = 0
}
