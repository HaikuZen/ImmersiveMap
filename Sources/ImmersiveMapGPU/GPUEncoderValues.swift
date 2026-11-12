// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

extension GPURenderEncoder {
    /// A value as small constant data, `MemoryLayout<Value>.stride` bytes,
    /// the size a shader's struct of the same layout takes. The bytes past
    /// the value's own size are zeros: passing `&value` with the stride as
    /// its length, as Metal code often does, reads past the value instead.
    package func setVertexValue<Value>(_ value: Value, index: Int) {
        withGPUConstantBytes(of: value) { setVertexBytes($0, length: $1, index: index) }
    }

    /// The same for the fragment function.
    package func setFragmentValue<Value>(_ value: Value, index: Int) {
        withGPUConstantBytes(of: value) { setFragmentBytes($0, length: $1, index: index) }
    }

    /// One instance of a run of vertices, the common draw.
    package func draw(_ topology: GPUPrimitiveTopology, vertexStart: Int, vertexCount: Int) {
        draw(topology, vertexStart: vertexStart, vertexCount: vertexCount, instanceCount: 1, baseInstance: 0)
    }

    /// One instance of a run of indices, from the first vertex of the buffer.
    package func drawIndexed(_ topology: GPUPrimitiveTopology, indexCount: Int, indexType: GPUIndexType,
                             indexBuffer: any GPUBuffer, indexBufferOffset: Int) {
        drawIndexed(topology, indexCount: indexCount, indexType: indexType,
                    indexBuffer: indexBuffer, indexBufferOffset: indexBufferOffset,
                    instanceCount: 1, baseVertex: 0, baseInstance: 0)
    }
}

extension GPUDevice {
    /// A buffer holding the elements' bytes, or nil for no elements (a
    /// device makes no buffer of no bytes) and when the allocation fails.
    package func makeBuffer<Element>(_ values: [Element], storage: GPUStorage) -> (any GPUBuffer)? {
        precondition(_isPOD(Element.self), "GPU buffer elements are plain values: \(Element.self) holds references")
        return values.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
            return makeBuffer(bytes: base, length: bytes.count, storage: storage)
        }
    }
}

/// A value's bytes as a shader reads constant data: the value's stride,
/// zeros after the value's own size. A backend's own code calls it too
/// (`GroundFogUniform+Metal.swift`), so every path sends the same bytes.
/// The value must be plain data: an array, a class or an existential would
/// send its reference, never its contents.
package func withGPUConstantBytes<Value>(of value: Value, _ body: (UnsafeRawPointer, Int) -> Void) {
    precondition(_isPOD(Value.self), "Constant data is a plain value: \(Value.self) holds references")
    let stride = MemoryLayout<Value>.stride
    guard MemoryLayout<Value>.size < stride else {
        // No tail padding: the value's own bytes are what the shader reads.
        withUnsafeBytes(of: value) { body($0.baseAddress!, stride) }
        return
    }
    withUnsafeTemporaryAllocation(byteCount: stride, alignment: MemoryLayout<Value>.alignment) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        withUnsafeBytes(of: value) { valueBytes in
            buffer.copyMemory(from: valueBytes)
        }
        body(UnsafeRawPointer(buffer.baseAddress!), stride)
    }
}
