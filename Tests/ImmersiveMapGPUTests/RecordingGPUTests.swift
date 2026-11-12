// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
import ImmersiveMapGPUTestSupport
import Testing

/// The recording GPU the features' tests draw with, and the value helpers
/// of the encoder.
struct RecordingGPUTests {
    private struct Padded: Equatable {
        var a: SIMD3<Float>
        var b: Float
        var c: UInt8
    }

    @Test func aValueIsPassedAtItsStrideWithZerosAfterIt() {
        let encoder = RecordingRenderEncoder()
        let value = Padded(a: SIMD3(1, 2, 3), b: 4, c: 5)
        encoder.setVertexValue(value, index: 2)
        encoder.setFragmentValue(Float(0.5), index: 0)
        guard case let .setVertexBytes(bytes, index) = encoder.commands[0] else {
            Issue.record("expected vertex bytes, got \(encoder.commands[0])")
            return
        }
        #expect(index == 2)
        #expect(bytes.count == MemoryLayout<Padded>.stride)
        #expect(bytes[MemoryLayout<Padded>.size...].allSatisfy { $0 == 0 })
        #expect(encoder.vertexValue(at: 2, as: Padded.self) == value)
        #expect(encoder.fragmentValue(at: 0, as: Float.self) == 0.5)
        #expect(encoder.vertexValue(at: 7, as: Float.self) == nil)
    }

    @Test func theDeviceKeepsWhatItMade() throws {
        let device = RecordingGPUDevice(shaderFunctions: ["vertexMain", "fragmentMain"])
        var values: [Float] = [1, 2, 3]
        let buffer = try #require(device.makeBuffer(bytes: &values, length: 12, storage: .shared) as? RecordingBuffer)
        #expect(buffer.values(as: Float.self) == [1, 2, 3])
        #expect(buffer.name == "buffer 0")
        #expect(device.makeBuffer(length: 0, storage: .shared) == nil)

        let descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "vertexMain"),
                                                     fragmentFunction: GPUShaderFunction(name: "fragmentMain"),
                                                     colorTargets: [GPUColorTarget(format: .bgra8Unorm)])
        let pipeline = try device.makeRenderPipeline(descriptor)
        #expect(device.pipelines == [descriptor])

        var missing = descriptor
        missing.fragmentFunction = GPUShaderFunction(name: "absent")
        #expect(throws: GPUError.missingFunction("absent")) { try device.makeRenderPipeline(missing) }

        let encoder = RecordingRenderEncoder()
        encoder.setPipeline(pipeline)
        encoder.setVertexBuffer(buffer, offset: 4, index: 0)
        encoder.draw(.point, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: 0)
        #expect(encoder.commands == [
            .setPipeline(descriptor),
            .setVertexBuffer("buffer 0", offset: 4, index: 0),
            .draw(.point, vertexStart: 0, vertexCount: 3, instanceCount: 1, baseInstance: 0),
        ])
    }

    @Test func aValueWithNoTailPaddingIsPassedAsItsOwnBytes() {
        var sent: [UInt8] = []
        let value = SIMD4<Float>(1, 2, 3, 4)
        withGPUConstantBytes(of: value) { bytes, length in
            sent = Array(UnsafeRawBufferPointer(start: bytes, count: length))
        }
        #expect(sent.count == MemoryLayout<SIMD4<Float>>.stride)
        #expect(sent == withUnsafeBytes(of: value) { Array($0) })
    }

    @Test func anArrayIsUploadedAsItsElementsAndNothingIsMadeForNone() throws {
        let device = RecordingGPUDevice()
        let buffer = try #require(device.makeBuffer([7, 8, 9] as [UInt16], storage: .shared) as? RecordingBuffer)
        #expect(buffer.length == 3 * MemoryLayout<UInt16>.stride)
        #expect(buffer.values(as: UInt16.self) == [7, 8, 9])
        #expect(device.makeBuffer([Float](), storage: .shared) == nil)
        #expect(device.buffers.count == 1)
    }

    @Test func theShortDrawsAreOneInstanceFromTheStart() throws {
        let device = RecordingGPUDevice()
        let indices = try #require(device.makeBuffer([0, 1, 2] as [UInt32], storage: .shared))
        let encoder = RecordingRenderEncoder()
        encoder.draw(.triangle, vertexStart: 3, vertexCount: 6)
        encoder.drawIndexed(.triangle, indexCount: 3, indexType: .uint32, indexBuffer: indices, indexBufferOffset: 4)
        #expect(encoder.commands == [
            .draw(.triangle, vertexStart: 3, vertexCount: 6, instanceCount: 1, baseInstance: 0),
            .drawIndexed(.triangle, indexCount: 3, indexType: .uint32, indexBuffer: "buffer 0", indexBufferOffset: 4,
                         instanceCount: 1, baseVertex: 0, baseInstance: 0),
        ])
    }

    @Test func aCommittedBufferHasCompleted() throws {
        let queue = try #require(RecordingGPUDevice().makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer() as? RecordingCommandBuffer)
        nonisolated(unsafe) var completed = false
        commandBuffer.addCompletedHandler { completed = true }
        commandBuffer.commit()
        #expect(completed)
        #expect(commandBuffer.committed)
    }
}
