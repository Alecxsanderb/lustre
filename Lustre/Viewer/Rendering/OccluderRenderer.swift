//
//  OccluderRenderer.swift
//  Lustre
//
//  Draws detected surfaces into a depth-only buffer so the composite pass can
//  hide the splats behind them.
//
//  Why it isn't done the obvious way: MetalSplatter sets
//  `depthCompareFunction = .always` on every pipeline variant, so splats
//  cannot be depth-tested against anything. Occlusion therefore has to happen
//  after the splat pass, in screen space, by comparing the depth the splat
//  pass wrote against the depth of the surfaces. See
//  `Lustre/Viewer/INTEGRATION.md`.
//

import Foundation
import Metal
import os
import simd

@MainActor
final class OccluderRenderer {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lustre",
                                    category: "OccluderRenderer")

    private enum Constants {
        /// Generous: an ARKit plane boundary is tens of vertices and a room
        /// rarely yields more than a handful of horizontal planes.
        static let maximumVertices = 8192
    }

    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private var vertexBuffers: [MTLBuffer] = []
    private var bufferIndex = 0
    private var vertices: [SIMD3<Float>] = []

    init?(device: MTLDevice, depthFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeDefaultLibrary(bundle: .main)

            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Occluder depth"
            descriptor.vertexFunction = library.makeFunction(name: "occluderVertex")
            // Depth-only: no color attachment and no fragment stage at all.
            descriptor.fragmentFunction = nil
            descriptor.vertexDescriptor = vertexDescriptor
            descriptor.depthAttachmentPixelFormat = depthFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)

            let depthDescriptor = MTLDepthStencilDescriptor()
            // A real depth test, unlike the splat pass: overlapping surfaces
            // must resolve to the nearest one.
            depthDescriptor.depthCompareFunction = .less
            depthDescriptor.isDepthWriteEnabled = true
            guard let state = device.makeDepthStencilState(descriptor: depthDescriptor) else {
                return nil
            }
            depthState = state
        } catch {
            Self.log.error("Couldn't build the occluder pipeline: \(error.localizedDescription)")
            return nil
        }
    }

    /// Renders every surface into `depthTexture`, cleared to the far plane.
    /// Returns false when there was nothing to draw, so the caller can skip
    /// the depth comparison entirely rather than testing against an empty
    /// buffer.
    @discardableResult
    func draw(planes: [DetectedPlane],
              viewProjection: simd_float4x4,
              into depthTexture: MTLTexture,
              commandBuffer: MTLCommandBuffer) -> Bool {
        buildGeometry(planes: planes)
        guard !vertices.isEmpty, let buffer = nextVertexBuffer() else { return false }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = .clear
        // 1.0 is the far plane in Metal's [0, 1] clip range: "nothing here".
        descriptor.depthAttachment.clearDepth = 1.0
        descriptor.depthAttachment.storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.label = "Occluder depth"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        // Surfaces are two-sided: the floor occludes whether you're above it
        // looking down or the plane estimate puts you slightly under it.
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var matrix = viewProjection
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        return true
    }

    // MARK: - Geometry

    private func buildGeometry(planes: [DetectedPlane]) {
        vertices.removeAll(keepingCapacity: true)

        for plane in planes {
            let outline = plane.outline
            guard outline.count >= 3 else { continue }

            // ARKit hands back a convex hull, so a fan from the centroid fills
            // it without a general triangulator.
            let centroid = outline.reduce(SIMD2<Float>.zero, +) / Float(outline.count)
            let center = world(centroid, on: plane)
            for index in outline.indices {
                guard vertices.count + 3 <= Constants.maximumVertices else { return }
                let a = world(outline[index], on: plane)
                let b = world(outline[(index + 1) % outline.count], on: plane)
                vertices.append(center)
                vertices.append(a)
                vertices.append(b)
            }
        }
    }

    private func world(_ local: SIMD2<Float>, on plane: DetectedPlane) -> SIMD3<Float> {
        (plane.transform * SIMD4<Float>(local.x, 0, local.y, 1)).xyz
    }

    /// One buffer per in-flight frame.
    ///
    /// A single shared buffer is a CPU/GPU race: `draw(in:)` allows up to
    /// `SplatRenderer.framesInFlight` command buffers outstanding, and Metal's
    /// hazard tracking doesn't stop the CPU from overwriting a `.storageModeShared`
    /// buffer that an earlier frame's GPU work is still reading. Cycling means a
    /// buffer is only rewritten once the frame that used it has completed.
    private func nextVertexBuffer() -> MTLBuffer? {
        if vertexBuffers.isEmpty {
            let length = MemoryLayout<SIMD3<Float>>.stride * Constants.maximumVertices
            vertexBuffers = (0..<SplatRenderer.framesInFlight).compactMap { index in
                let buffer = device.makeBuffer(length: length, options: .storageModeShared)
                buffer?.label = "Occluder vertices \(index)"
                return buffer
            }
            guard vertexBuffers.count == SplatRenderer.framesInFlight else {
                vertexBuffers.removeAll()
                return nil
            }
        }

        bufferIndex = (bufferIndex + 1) % vertexBuffers.count
        let buffer = vertexBuffers[bufferIndex]
        vertices.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        return buffer
    }
}
