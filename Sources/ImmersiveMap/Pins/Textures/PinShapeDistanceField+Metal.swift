// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

extension PinShapeDistanceField {
    /// The texture of a shape's distance field. A shape without a frame has
    /// no field, and gets a single texel for the shader's texture slot. The
    /// built-in bubble has its own texture in the resources, and none here.
    static func makeTexture(device: MTLDevice, shape: PinShape) -> MTLTexture? {
        let side: Int
        let values: [UInt16]
        switch shape.outline {
        case .bubble:
            return nil
        case .paths, .mask:
            guard let field = encodedField(for: shape) else {
                return nil
            }
            side = textureSize
            values = field
        case .picture:
            side = 1
            values = [framelessTexel]
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm,
                                                                  width: side,
                                                                  height: side,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        texture.label = "Pin shape distance field"
        values.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, side, side),
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: side * MemoryLayout<UInt16>.stride)
        }
        return texture
    }

}
