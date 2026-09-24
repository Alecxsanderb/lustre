//
//  VertexBufferRing.swift
//  Lustre
//
//  One CPU-written vertex buffer per in-flight frame, shared by the overlay
//  passes that rebuild their geometry every frame.
//

import Foundation
import Metal

/// A single shared buffer is a CPU/GPU race: `draw(in:)` allows up to
/// `SplatRenderer.framesInFlight` command buffers outstanding, and Metal's
/// hazard tracking doesn't stop the CPU from overwriting a `.storageModeShared`
/// buffer that an earlier frame's GPU work is still reading. Cycling means a
/// buffer is only rewritten once the frame that used it has completed.
struct VertexBufferRing<Element> {
    private let device: MTLDevice
    private let capacity: Int
    private let label: String
    private var buffers: [MTLBuffer] = []
    private var index = 0

    /// - Parameter capacity: maximum elements per frame. Buffers are allocated
    ///   lazily at this size on first use, then reused for the ring's lifetime.
    init(device: MTLDevice, capacity: Int, label: String) {
        self.device = device
        self.capacity = capacity
        self.label = label
    }

    /// Copies `elements` into the next buffer in the ring and returns it, or
    /// nil if the buffers couldn't be allocated. Anything past `capacity` is
    /// dropped rather than written off the end.
    mutating func next(filledWith elements: [Element]) -> MTLBuffer? {
        if buffers.isEmpty {
            let length = MemoryLayout<Element>.stride * capacity
            buffers = (0..<SplatRenderer.framesInFlight).compactMap { slot in
                let buffer = device.makeBuffer(length: length, options: .storageModeShared)
                buffer?.label = "\(label) \(slot)"
                return buffer
            }
            guard buffers.count == SplatRenderer.framesInFlight else {
                buffers.removeAll()
                return nil
            }
        }

        index = (index + 1) % buffers.count
        let buffer = buffers[index]
        let count = min(elements.count, capacity)
        elements.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            buffer.contents().copyMemory(from: base,
                                         byteCount: count * MemoryLayout<Element>.stride)
        }
        return buffer
    }
}
