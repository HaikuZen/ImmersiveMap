// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

extension GPURenderEncoder {
    /// A value as small constant data, `MemoryLayout<Value>.stride` bytes,
    /// the size a shader's struct of the same layout takes. The bytes past
    /// the value's own size are zeros: passing `&value` with the stride as
    /// its length, as Metal code often does, reads past the value instead.
    package func setVertexValue<Value>(_ value: Value, index: Int) {
        withStridePaddedBytes(of: value) { setVertexBytes($0, length: $1, index: index) }
    }

    /// The same for the fragment function.
    package func setFragmentValue<Value>(_ value: Value, index: Int) {
        withStridePaddedBytes(of: value) { setFragmentBytes($0, length: $1, index: index) }
    }
}

private func withStridePaddedBytes<Value>(of value: Value, _ body: (UnsafeRawPointer, Int) -> Void) {
    let stride = MemoryLayout<Value>.stride
    withUnsafeTemporaryAllocation(byteCount: stride, alignment: MemoryLayout<Value>.alignment) { buffer in
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        withUnsafeBytes(of: value) { valueBytes in
            buffer.copyMemory(from: valueBytes)
        }
        body(UnsafeRawPointer(buffer.baseAddress!), stride)
    }
}
