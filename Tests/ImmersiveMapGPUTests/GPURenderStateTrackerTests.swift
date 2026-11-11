// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import Testing

/// The tracker a WebGPU backend picks its pipeline variants with.
struct GPURenderStateTrackerTests {
    private final class Object {}

    @Test func aDrawBeforeAPipelineIsRefused() {
        var tracker = GPURenderStateTracker()
        #expect(throws: GPURenderStateTracker.DrawError.noPipeline) { try tracker.variantForDraw() }
    }

    @Test func aNewPassStartsFromMetalsDefaults() throws {
        let pipeline = Object()
        var tracker = GPURenderStateTracker()
        tracker.setPipeline(pipeline)
        let (variant, needsBinding) = try tracker.variantForDraw()
        #expect(needsBinding)
        #expect(variant.pipeline == ObjectIdentifier(pipeline))
        #expect(variant.depthStencil == nil)
        #expect(variant.cullMode == .none)
        #expect(variant.frontFacing == .clockwise)
        #expect(variant.depthBias == .none)
        #expect(variant.depthClipMode == .clip)
    }

    @Test func onlyAChangeOfStateBindsAgain() throws {
        let pipeline = Object(), other = Object(), depth = Object()
        var tracker = GPURenderStateTracker()
        tracker.setPipeline(pipeline)
        tracker.setDepthStencilState(depth)
        #expect(try tracker.variantForDraw().needsBinding)
        #expect(try tracker.variantForDraw().needsBinding == false)

        // Setting what is already set changes nothing.
        tracker.setCullMode(.none)
        tracker.setPipeline(pipeline)
        #expect(try tracker.variantForDraw().needsBinding == false)

        tracker.setCullMode(.back)
        let culled = try tracker.variantForDraw()
        #expect(culled.needsBinding)
        #expect(culled.variant.cullMode == .back)

        tracker.setFrontFacing(.counterClockwise)
        tracker.setDepthBias(GPUDepthBias(constant: 1, slopeScale: 2, clamp: 0))
        tracker.setDepthClipMode(.clamp)
        let changed = try tracker.variantForDraw()
        #expect(changed.needsBinding)
        #expect(changed.variant.frontFacing == .counterClockwise)
        #expect(changed.variant.depthClipMode == .clamp)

        tracker.setPipeline(other)
        #expect(try tracker.variantForDraw().variant.pipeline == ObjectIdentifier(other))
    }

    @Test func theSameStateIsTheSameVariant() throws {
        let pipeline = Object(), depth = Object()
        var first = GPURenderStateTracker(), second = GPURenderStateTracker()
        for index in 0 ..< 2 {
            var tracker = index == 0 ? first : second
            tracker.setPipeline(pipeline)
            tracker.setDepthStencilState(depth)
            tracker.setCullMode(.back)
            if index == 0 { first = tracker } else { second = tracker }
        }
        #expect(try first.variantForDraw().variant == second.variantForDraw().variant)
        var cache: Set<GPURenderStateTracker.Variant> = []
        cache.insert(try first.variantForDraw().variant)
        cache.insert(try second.variantForDraw().variant)
        #expect(cache.count == 1)
    }
}
