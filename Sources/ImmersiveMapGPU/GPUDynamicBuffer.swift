// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// A typed buffer that is reused and only grows: a new allocation at twice
/// the capacity when a count no longer fits, never a smaller one, so a hot
/// path that uploads every frame stops allocating once it has seen its
/// largest count. Its bytes are the CPU's to write (`.shared`).
package final class GPUDynamicBuffer<Element> {
    private let device: any GPUDevice
    private let minimumCapacity: Int

    package private(set) var buffer: any GPUBuffer
    package private(set) var capacity: Int

    package init(device: any GPUDevice, minimumCapacity: Int = 1) {
        let minimum = max(1, minimumCapacity)
        self.device = device
        self.minimumCapacity = minimum
        capacity = minimum
        buffer = Self.makeBuffer(device: device, elementCount: minimum)
    }

    /// The buffer, holding at least `count` elements. A buffer that grew is
    /// a new one: what the old one held is not carried over.
    @discardableResult
    package func ensureCapacity(count: Int) -> any GPUBuffer {
        let requested = max(minimumCapacity, count)
        guard requested > capacity else {
            return buffer
        }
        var grown = capacity
        while grown < requested {
            let (doubled, overflow) = grown.multipliedReportingOverflow(by: 2)
            grown = overflow ? requested : doubled
        }
        buffer = Self.makeBuffer(device: device, elementCount: grown)
        capacity = grown
        return buffer
    }

    private static func makeBuffer(device: any GPUDevice, elementCount: Int) -> any GPUBuffer {
        let (length, overflow) = max(1, elementCount).multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        precondition(overflow == false, "A GPU buffer of \(elementCount) \(Element.self) overflows")
        guard let buffer = device.makeBuffer(length: length, storage: .shared) else {
            fatalError("Failed to allocate a GPU buffer of \(length) bytes for \(Element.self)")
        }
        return buffer
    }
}

/// One `GPUDynamicBuffer` per frame in flight: the CPU writes a frame's
/// slot while the GPU may still read the others.
package final class GPUFrameSlottedBuffer<Element> {
    private let slots: [GPUDynamicBuffer<Element>]

    package init(device: any GPUDevice, slotsCount: Int, minimumCapacity: Int = 1) {
        precondition(slotsCount > 0, "A frame-slotted buffer needs at least one slot")
        slots = (0 ..< slotsCount).map { _ in GPUDynamicBuffer(device: device, minimumCapacity: minimumCapacity) }
    }

    @discardableResult
    package func ensureCapacity(slot: Int, count: Int) -> any GPUBuffer {
        store(slot).ensureCapacity(count: count)
    }

    package func buffer(for slot: Int) -> any GPUBuffer {
        store(slot).buffer
    }

    package func capacity(for slot: Int) -> Int {
        store(slot).capacity
    }

    private func store(_ slot: Int) -> GPUDynamicBuffer<Element> {
        precondition(slots.indices.contains(slot), "Frame slot \(slot) is out of bounds")
        return slots[slot]
    }
}
