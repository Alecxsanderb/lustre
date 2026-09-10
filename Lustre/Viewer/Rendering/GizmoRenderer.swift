//
//  GizmoRenderer.swift
//  Lustre
//
//  Draws the placement indicators: axis bars at the splat's center, a drop
//  line to the surface beneath it, a ring where that line lands, and outlines
//  of detected planes.
//
//  Runs as a final pass into the drawable, after splats (and after the
//  passthrough composite), with `loadAction = .load` so it draws over whatever
//  is already there.
//

import Foundation
import Metal
import os
import simd

@MainActor
final class GizmoRenderer {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lustre",
                                    category: "GizmoRenderer")

    /// Matches the `[[stage_in]]` layout in Gizmo.metal.
    private struct Vertex {
        var position: SIMD3<Float>
        var color: SIMD4<Float>
    }

    private enum Constants {
        /// Axis bar half-length, meters. Fixed rather than proportional to the
        /// splat: it's a position indicator, not a scale readout, and a
        /// gizmo that grows with a 100× splat would fill the screen.
        static let axisLength: Float = 0.25
        static let ringRadius: Float = 0.12
        static let ringSegments = 32
        /// Above this the drop line is drawn dashed rather than solid, as a
        /// hint the splat is floating a long way off the surface.
        static let longDropDistance: Float = 3.0
        static let maximumVertices = 4096
    }

    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private var vertexBuffer: MTLBuffer?
    private var vertices: [Vertex] = []

    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeDefaultLibrary(bundle: .main)

            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float3
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.attributes[1].format = .float4
            vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
            vertexDescriptor.attributes[1].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Gizmo"
            descriptor.vertexFunction = library.makeFunction(name: "gizmoVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "gizmoFragment")
            descriptor.vertexDescriptor = vertexDescriptor
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            // Premultiplied, matching the fragment shader's output.
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Self.log.error("Couldn't build the gizmo pipeline: \(error.localizedDescription)")
            return nil
        }
    }

    /// - Parameters:
    ///   - splatCenter: the splat's pivot in world space.
    ///   - planes: detected surfaces; empty when detection is off.
    ///   - viewProjection: projection × view. **Not** including the model
    ///     matrix — the gizmo is authored directly in world space.
    func draw(splatCenter: SIMD3<Float>,
              planes: [DetectedPlane],
              isPlacing: Bool,
              viewProjection: simd_float4x4,
              into target: MTLTexture,
              commandBuffer: MTLCommandBuffer) {
        buildGeometry(splatCenter: splatCenter, planes: planes, isPlacing: isPlacing)
        guard !vertices.isEmpty, let buffer = updatedVertexBuffer() else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        // Load, not clear: splats (or the camera composite) are already there.
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.label = "Gizmo"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        var matrix = viewProjection
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    // MARK: - Geometry

    private func buildGeometry(splatCenter: SIMD3<Float>,
                               planes: [DetectedPlane],
                               isPlacing: Bool) {
        vertices.removeAll(keepingCapacity: true)

        // Axis bars. Red/green/blue for X/Y/Z, the near-universal convention.
        let alpha: Float = isPlacing ? 1.0 : 0.85
        addLine(from: splatCenter - SIMD3(Constants.axisLength, 0, 0),
                to: splatCenter + SIMD3(Constants.axisLength, 0, 0),
                color: SIMD4(1.0, 0.25, 0.25, alpha))
        addLine(from: splatCenter - SIMD3(0, Constants.axisLength, 0),
                to: splatCenter + SIMD3(0, Constants.axisLength, 0),
                color: SIMD4(0.3, 1.0, 0.35, alpha))
        addLine(from: splatCenter - SIMD3(0, 0, Constants.axisLength),
                to: splatCenter + SIMD3(0, 0, Constants.axisLength),
                color: SIMD4(0.35, 0.55, 1.0, alpha))

        // Drop line to the surface directly below the splat, plus a ring where
        // it lands — this is what makes the height readable.
        if let groundY = supportingPlaneHeight(below: splatCenter, planes: planes) {
            let foot = SIMD3(splatCenter.x, groundY, splatCenter.z)
            let distance = splatCenter.y - groundY
            let color = SIMD4<Float>(1.0, 0.85, 0.3, alpha)

            if distance > Constants.longDropDistance {
                addDashedLine(from: splatCenter, to: foot, color: color)
            } else {
                addLine(from: splatCenter, to: foot, color: color)
            }
            addRing(center: foot, radius: Constants.ringRadius, color: color)
        }

        // Outlines of every detected plane, so it's obvious what the app has
        // actually found versus what you can see.
        for plane in planes {
            addPlaneOutline(plane, color: SIMD4(0.5, 0.9, 1.0, alpha * 0.5))
        }
    }

    /// Highest plane below the splat, or nil if it's below all of them.
    private func supportingPlaneHeight(below point: SIMD3<Float>,
                                       planes: [DetectedPlane]) -> Float? {
        planes
            .map { $0.transform.columns.3.y }
            .filter { $0 < point.y }
            .max()
    }

    private func addLine(from start: SIMD3<Float>, to end: SIMD3<Float>, color: SIMD4<Float>) {
        guard vertices.count + 2 <= Constants.maximumVertices else { return }
        vertices.append(Vertex(position: start, color: color))
        vertices.append(Vertex(position: end, color: color))
    }

    private func addDashedLine(from start: SIMD3<Float>,
                               to end: SIMD3<Float>,
                               color: SIMD4<Float>) {
        let segments = 12
        for i in stride(from: 0, to: segments, by: 2) {
            let t0 = Float(i) / Float(segments)
            let t1 = Float(i + 1) / Float(segments)
            addLine(from: mix(start, end, t: t0), to: mix(start, end, t: t1), color: color)
        }
    }

    private func addRing(center: SIMD3<Float>, radius: Float, color: SIMD4<Float>) {
        var previous = center + SIMD3(radius, 0, 0)
        for i in 1...Constants.ringSegments {
            let angle = Float(i) / Float(Constants.ringSegments) * 2 * .pi
            let next = center + SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
            addLine(from: previous, to: next, color: color)
            previous = next
        }
    }

    private func addPlaneOutline(_ plane: DetectedPlane, color: SIMD4<Float>) {
        let halfWidth = plane.extent.x / 2
        let halfDepth = plane.extent.y / 2
        let corners = [
            SIMD3<Float>(-halfWidth, 0, -halfDepth),
            SIMD3<Float>( halfWidth, 0, -halfDepth),
            SIMD3<Float>( halfWidth, 0,  halfDepth),
            SIMD3<Float>(-halfWidth, 0,  halfDepth),
        ].map { corner -> SIMD3<Float> in
            (plane.transform * SIMD4<Float>(corner, 1)).xyz
        }
        for i in corners.indices {
            addLine(from: corners[i], to: corners[(i + 1) % corners.count], color: color)
        }
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    private func updatedVertexBuffer() -> MTLBuffer? {
        let length = MemoryLayout<Vertex>.stride * Constants.maximumVertices
        if vertexBuffer == nil {
            vertexBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            vertexBuffer?.label = "Gizmo vertices"
        }
        guard let vertexBuffer else { return nil }
        vertices.withUnsafeBytes { source in
            vertexBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        return vertexBuffer
    }
}
