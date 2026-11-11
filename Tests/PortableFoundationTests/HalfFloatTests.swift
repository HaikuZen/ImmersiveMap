// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import PortableFoundation
import Testing

/// The half precision conversion by known answers, and against Swift's own
/// `Float16` where the platform has it.
struct HalfFloatTests {
    @Test func knownValues() {
        #expect(HalfFloat.bits(0) == 0x0000)
        #expect(HalfFloat.bits(-0.0) == 0x8000)
        #expect(HalfFloat.bits(1) == 0x3C00)
        #expect(HalfFloat.bits(-2) == 0xC000)
        #expect(HalfFloat.bits(65504) == 0x7BFF)
        #expect(HalfFloat.bits(65520) == 0x7C00)
        #expect(HalfFloat.bits(.infinity) == 0x7C00)
        #expect(HalfFloat.bits(-.infinity) == 0xFC00)
        #expect(HalfFloat.bits(.nan) & 0x7C00 == 0x7C00 && HalfFloat.bits(.nan) & 0x3FF != 0)
        #expect(HalfFloat.bits(Float(sign: .plus, exponent: -24, significand: 1)) == 0x0001)
        #expect(HalfFloat.bits(Float(sign: .plus, exponent: -26, significand: 1)) == 0x0000)
        // 1 + 2^-11 lies halfway between two halves: it goes to the even one.
        #expect(HalfFloat.bits(1 + Float(sign: .plus, exponent: -11, significand: 1)) == 0x3C00)
        #expect(HalfFloat.value(bits: 0x3C00) == 1)
        #expect(HalfFloat.value(bits: 0x0001) == Float(sign: .plus, exponent: -24, significand: 1))
        #expect(HalfFloat.value(bits: 0xFC00) == -.infinity)
        #expect(HalfFloat.value(bits: 0x7E00).isNaN)
    }

    @Test func everyHalfComesBackToItself() {
        for bits in UInt16.min ... UInt16.max where HalfFloat.value(bits: bits).isNaN == false {
            #expect(HalfFloat.bits(HalfFloat.value(bits: bits)) == bits)
        }
    }

    #if !(os(macOS) && arch(x86_64))
    @Test func theConversionIsFloat16s() {
        var generator = SystemRandomNumberGenerator()
        var values: [Float] = [0, 1, 1e-8, 5.96e-8, 6.1e-5, 65504, 65519.99, 1e9, -3.14159]
        for _ in 0 ..< 200_000 {
            values.append(Float(bitPattern: UInt32.random(in: 0 ... UInt32.max, using: &generator)))
        }
        for value in values where value.isNaN == false {
            #expect(HalfFloat.bits(value) == Float16(value).bitPattern, "\(value)")
        }
        for bits in UInt16.min ... UInt16.max where Float16(bitPattern: bits).isNaN == false {
            #expect(HalfFloat.value(bits: bits) == Float(Float16(bitPattern: bits)))
        }
    }
    #endif
}
