// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// Half precision floats as their bits, for the platforms where Swift's
// `Float16` is missing (macOS on Intel) and Accelerate's conversion is too
// (everything not Apple's). The conversion is IEEE 754's: round to nearest,
// ties to even, with infinities, NaNs and subnormals kept.

public enum HalfFloat {
    /// The bits of the half precision float nearest to `value`.
    public static func bits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF)
        let mantissa = bits & 0x7F_FFFF

        // Infinity and NaN. A NaN keeps a payload bit, so it stays a NaN.
        if exponent == 0xFF {
            return sign | 0x7C00 | (mantissa == 0 ? 0 : UInt16(0x200 | (mantissa >> 13)))
        }
        let halfExponent = exponent - 127 + 15
        // Too large for a half: infinity.
        if halfExponent >= 0x1F {
            return sign | 0x7C00
        }
        if halfExponent <= 0 {
            // A subnormal half, or zero: the implicit bit joins the mantissa,
            // which is shifted down by the exponent's shortfall.
            if halfExponent < -10 {
                return sign
            }
            let full = mantissa | 0x80_0000
            let shift = UInt32(14 - halfExponent)
            return sign | UInt16(truncatingIfNeeded: roundedShift(full, by: shift))
        }
        // A normal half. A carry out of the mantissa raises the exponent,
        // up to infinity, which is the correct rounding.
        let rounded = roundedShift(mantissa, by: 13)
        return sign | UInt16(truncatingIfNeeded: (UInt32(halfExponent) << 10) + rounded)
    }

    /// The float the half precision bits stand for, exactly.
    public static func value(bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        if exponent == 0x1F {
            return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13))
        }
        if exponent == 0 {
            // Zero or a subnormal: mantissa × 2^-24.
            let magnitude = Float(mantissa) * Float(sign: .plus, exponent: -24, significand: 1)
            return sign == 0 ? magnitude : -magnitude
        }
        return Float(bitPattern: sign | (UInt32(exponent - 15 + 127) << 23) | (mantissa << 13))
    }

    /// `value >> shift`, rounded to nearest with ties to even.
    private static func roundedShift(_ value: UInt32, by shift: UInt32) -> UInt32 {
        let kept = value >> shift
        let remainder = value & ((1 << shift) - 1)
        let half: UInt32 = 1 << (shift - 1)
        if remainder > half || (remainder == half && kept & 1 == 1) {
            return kept + 1
        }
        return kept
    }
}
