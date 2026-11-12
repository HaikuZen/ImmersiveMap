// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import Metal

extension GlobeLightUniform {
    /// Binds the light for the features that still draw with the render
    /// core's Metal encoder, with the bytes the GPU interface's binding
    /// sends, and no wrapper made per call. Goes when the last of them moves
    /// onto the GPU interface.
    static func bind(_ uniform: GlobeLightUniform, encoder: MTLRenderCommandEncoder) {
        withGPUConstantBytes(of: uniform) { bytes, length in
            encoder.setFragmentBytes(bytes, length: length, index: bufferIndex)
        }
    }
}
