// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import PortableFoundation

/// Turns a pin shape into the distance field the pin shader cuts its frame
/// from: for every texel, how far it is from the shape's edge, negative
/// inside. Baked on the CPU once per map, so a map's author gives a path and
/// never a prepared texture.
enum PinShapeDistanceField {
    /// The side of the baked texture, in texels.
    static let textureSize = 256
    /// The shape is filled at this many samples per texel side before the
    /// distances are taken, which places its edge to a quarter of a texel.
    static let supersampling = 2
    /// The part of the texture left empty on every side of the shape, so that
    /// the soft edge of a shape that touches its square is not cut.
    static let margin: CGFloat = 0.02
    /// The distance, in texels, the texture's range of values spans to each
    /// side of the edge. Wider than any outline or inset a pin can have.
    static let distanceRangeTexels: Float = 128.0

    /// The signed distance of every sample to the shape's edge, in samples,
    /// negative inside.
    static func signedDistances(inside: [Bool], side: Int) -> [Float] {
        let toInside = squaredDistances(toSamplesWhere: inside, side: side)
        let toOutside = squaredDistances(toSamplesWhere: inside.map { !$0 }, side: side)
        var distances = [Float](repeating: 0.0, count: side * side)
        for index in 0..<distances.count {
            // The edge runs between two samples, half a sample from each.
            if inside[index] {
                distances[index] = -(toOutside[index].squareRoot() - 0.5)
            } else {
                distances[index] = toInside[index].squareRoot() - 0.5
            }
        }
        return distances
    }

    /// The field as the texture stores it: `textureSize` squared 16-bit
    /// values, 0.5 on the edge, larger inside. Nil for a shape with no field
    /// of its own (the built-in bubble, a bare picture), and where the
    /// shape's coverage cannot be had (no host drawer off Apple's
    /// platforms).
    static func encodedField(for shape: PinShape) -> [UInt16]? {
        let inside: [Bool]?
        switch shape.outline {
        case .bubble, .picture:
            return nil
        case .paths(let parts):
            inside = coverage(paths: parts, side: fineSide)
        case .mask(let mask):
            inside = coverage(mask: mask, side: fineSide)
        }
        return inside.map { encodedField(inside: $0) }
    }

    /// The single texel a shape without a frame binds, wholly inside.
    static var framelessTexel: UInt16 {
        encode(distanceTexels: -distanceRangeTexels)
    }

#if !canImport(CoreGraphics)
    /// The parts' coverage, from the host's drawer.
    static func coverage(paths: [PinShapePath], side: Int) -> [Bool]? {
        guard let inside = PinPictureHost.drawer?.coverage(of: paths, side: side, margin: Double(margin)),
              inside.count == side * side else {
            return nil
        }
        return inside
    }

    /// A mask's coverage: the picture stretched into the square inside the
    /// margin, over black, inside where its grey is at least half.
    static func coverage(mask: PinImage, side: Int) -> [Bool]? {
        guard case .pixels(let pixels) = mask.storage else {
            return nil
        }
        let inset = Int((margin * CGFloat(side)).rounded())
        let inner = max(side - 2 * inset, 1)
        let fitted = PinPixelResampler.resample(pixels,
                                                width: mask.width,
                                                height: mask.height,
                                                toWidth: inner,
                                                height: inner)
        var inside = [Bool](repeating: false, count: side * side)
        for y in 0..<inner {
            for x in 0..<inner {
                let index = (y * inner + x) * 4
                // Premultiplied over black: the colour as it stands. Rec. 601
                // weights, B G R in the texel.
                let grey = 0.114 * Double(fitted[index])
                    + 0.587 * Double(fitted[index + 1])
                    + 0.299 * Double(fitted[index + 2])
                let row = y + inset
                let column = x + inset
                if row < side, column < side {
                    inside[row * side + column] = grey >= 127.5
                }
            }
        }
        return inside
    }
#endif

    /// The side of the grid the shape is filled on.
    static var fineSide: Int {
        textureSize * supersampling
    }

    /// `inside` is a grid of `fineSide` squared samples.
    static func encodedField(inside: [Bool]) -> [UInt16] {
        let fineSide = fineSide
        let fine = signedDistances(inside: inside, side: fineSide)
        var encoded = [UInt16](repeating: 0, count: textureSize * textureSize)
        let samplesPerTexel = Float(supersampling * supersampling)
        for y in 0..<textureSize {
            for x in 0..<textureSize {
                var sum: Float = 0.0
                for dy in 0..<supersampling {
                    for dx in 0..<supersampling {
                        sum += fine[(y * supersampling + dy) * fineSide + x * supersampling + dx]
                    }
                }
                let distanceTexels = sum / samplesPerTexel / Float(supersampling)
                encoded[y * textureSize + x] = encode(distanceTexels: distanceTexels)
            }
        }
        return encoded
    }

    static func encode(distanceTexels: Float) -> UInt16 {
        let unit = 0.5 - distanceTexels / (2.0 * distanceRangeTexels)
        return UInt16((min(max(unit, 0.0), 1.0) * 65535.0).rounded())
    }

    /// The texture of a shape's distance field: 16-bit fractions where the
    /// device has them (Metal), 16-bit floats of the same values elsewhere
    /// (WebGPU, where `r16unorm` is optional). A shape without a frame has
    /// no field, and gets a single texel for the shader's texture slot. The
    /// built-in bubble has its own texture in the resources, and none here,
    /// as has a shape whose coverage cannot be had.
    static func makeTexture(device: any GPUDevice, shape: PinShape) -> (any GPUTexture)? {
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
        let unorm = device.features.contains(.unorm16Textures)
        var descriptor = GPUTextureDescriptor(format: unorm ? .r16Unorm : .r16Float, width: side, height: side)
        descriptor.usage = .shaderRead
        descriptor.storage = .shared
        descriptor.label = "Pin shape distance field"
        guard let texture = device.makeTexture(descriptor) else {
            return nil
        }
        let texels = unorm ? values : values.map(halfBits(ofUnorm:))
        texels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(x: 0, y: 0, width: side, height: side, mipmapLevel: 0, slice: 0,
                            bytes: baseAddress, bytesPerRow: side * MemoryLayout<UInt16>.stride)
        }
        return texture
    }

    /// Whether the engine can bake the shape's field here: on Apple's
    /// platforms always, elsewhere a path shape needs the host's drawer.
    static func canBake(_ shape: PinShape) -> Bool {
        switch shape.outline {
        case .bubble, .picture, .mask:
            return true
        case .paths:
            #if canImport(CoreGraphics)
            return true
            #else
            return PinPictureHost.drawer != nil
            #endif
        }
    }

    /// The IEEE half-precision bits of a 16-bit fraction's value
    /// (`value / 65535`), rounded to nearest even, for a texture of 16-bit
    /// floats. Values are in [0, 1], so no infinity or NaN arises.
    static func halfBits(ofUnorm value: UInt16) -> UInt16 {
        let float = Float(value) / 65535.0
        let bits = float.bitPattern
        let exponent = Int((bits >> 23) & 0xFF) - 127
        var mantissa = bits & 0x7F_FFFF
        if float == 0 {
            return 0
        }
        if exponent < -14 {
            // Subnormal half: the value in units of 2^-24.
            let shift = UInt32(-exponent - 14 + 13)
            mantissa |= 0x80_0000
            guard shift < 32 else { return 0 }
            var half = mantissa >> shift
            let remainder = mantissa & ((1 << shift) - 1)
            let halfway: UInt32 = 1 << (shift - 1)
            if remainder > halfway || (remainder == halfway && (half & 1) == 1) {
                half += 1
            }
            return UInt16(half)
        }
        var half = (UInt32(exponent + 15) << 10) | (mantissa >> 13)
        let remainder = mantissa & 0x1FFF
        if remainder > 0x1000 || (remainder == 0x1000 && (half & 1) == 1) {
            half += 1
        }
        return UInt16(half)
    }

    // MARK: - Distance transform

    private static let far: Float = 1.0e12

    /// For every sample, the squared distance to the nearest sample that is
    /// set: the exact Euclidean transform, one pass along the rows and one
    /// along the columns (Felzenszwalb and Huttenlocher).
    private static func squaredDistances(toSamplesWhere isSet: [Bool], side: Int) -> [Float] {
        var grid = isSet.map { $0 ? Float(0.0) : far }
        var line = [Float](repeating: 0.0, count: side)
        var result = [Float](repeating: 0.0, count: side)
        var parabolas = [Int](repeating: 0, count: side)
        var bounds = [Float](repeating: 0.0, count: side + 1)

        for y in 0..<side {
            for x in 0..<side { line[x] = grid[y * side + x] }
            transformLine(line, into: &result, parabolas: &parabolas, bounds: &bounds)
            for x in 0..<side { grid[y * side + x] = result[x] }
        }
        for x in 0..<side {
            for y in 0..<side { line[y] = grid[y * side + x] }
            transformLine(line, into: &result, parabolas: &parabolas, bounds: &bounds)
            for y in 0..<side { grid[y * side + x] = result[y] }
        }
        return grid
    }

    /// The lower envelope of the parabolas that stand on a line's samples.
    private static func transformLine(_ line: [Float],
                                      into result: inout [Float],
                                      parabolas: inout [Int],
                                      bounds: inout [Float]) {
        let count = line.count
        var last = 0
        parabolas[0] = 0
        bounds[0] = -Float.greatestFiniteMagnitude
        bounds[1] = Float.greatestFiniteMagnitude
        for sample in 1..<count {
            var crossing: Float
            while true {
                let other = parabolas[last]
                crossing = ((line[sample] + Float(sample * sample))
                            - (line[other] + Float(other * other)))
                    / Float(2 * (sample - other))
                if crossing <= bounds[last], last > 0 {
                    last -= 1
                } else {
                    break
                }
            }
            last += 1
            parabolas[last] = sample
            bounds[last] = crossing
            bounds[last + 1] = Float.greatestFiniteMagnitude
        }
        var current = 0
        for sample in 0..<count {
            while bounds[current + 1] < Float(sample) {
                current += 1
            }
            let offset = Float(sample - parabolas[current])
            result[sample] = offset * offset + line[parabolas[current]]
        }
    }
}
