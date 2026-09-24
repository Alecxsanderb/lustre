//
//  GizmoRenderer.swift
//  Lustre
//
//  Draws the placement indicators: axis bars at the splat's center with
//  real-world measuring notches, a drop line to the surface beneath it, a ring
//  where that line lands, and outlines of detected planes.
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
        static let ringSegments = 32
        /// Above this the drop line is drawn dashed rather than solid, as a
        /// hint the splat is floating a long way off the surface.
        static let longDropDistance: Float = 3.0
        static let maximumVertices = 4096
        /// Notch half-length as a fraction of the tick interval, so the marks
        /// stay proportioned however coarse the ruler gets.
        static let minorTickFraction: Float = 0.18
        static let majorTickFraction: Float = 0.42
    }

    private let pipelineState: MTLRenderPipelineState
    private var vertexRing: VertexBufferRing<Vertex>
    private var vertices: [Vertex] = []

    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        vertexRing = VertexBufferRing(device: device,
                                      capacity: Constants.maximumVertices,
                                      label: "Gizmo vertices")
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
    ///   - axisLength: half-length of each bar, in **meters of real space**.
    ///     Sized from the splat so the ruler spans something comparable to what
    ///     you're looking at.
    ///   - ruler: notch spacing, or nil to draw plain bars.
    ///   - planes: detected surfaces; empty when detection is off.
    ///   - viewProjection: projection × view. **Not** including the model
    ///     matrix — the gizmo is authored directly in world space.
    func draw(splatCenter: SIMD3<Float>,
              axisLength: Float,
              ruler: RulerScale?,
              planes: [DetectedPlane],
              isPlacing: Bool,
              viewProjection: simd_float4x4,
              into target: MTLTexture,
              commandBuffer: MTLCommandBuffer) {
        buildGeometry(splatCenter: splatCenter,
                      axisLength: axisLength,
                      ruler: ruler,
                      planes: planes,
                      isPlacing: isPlacing)
        guard !vertices.isEmpty, let buffer = vertexRing.next(filledWith: vertices) else { return }

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
                               axisLength: Float,
                               ruler: RulerScale?,
                               planes: [DetectedPlane],
                               isPlacing: Bool) {
        vertices.removeAll(keepingCapacity: true)

        // Axis bars. Red/green/blue for X/Y/Z, the near-universal convention.
        // They're drawn in world space along world axes, not the splat's own —
        // the point is to measure the room, and a ruler that inherits the
        // splat's arbitrary scale measures nothing.
        let alpha: Float = isPlacing ? 1.0 : 0.85
        let length = max(axisLength, 1e-3)
        let axes: [(direction: SIMD3<Float>, tick: SIMD3<Float>, color: SIMD4<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD4(1.0, 0.25, 0.25, alpha)),
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD4(0.3, 1.0, 0.35, alpha)),
            (SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD4(0.35, 0.55, 1.0, alpha)),
        ]
        for axis in axes {
            addLine(from: splatCenter - axis.direction * length,
                    to: splatCenter + axis.direction * length,
                    color: axis.color)
            if let ruler {
                addTicks(center: splatCenter,
                         direction: axis.direction,
                         tickDirection: axis.tick,
                         length: length,
                         ruler: ruler,
                         color: axis.color)
            }
        }

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
            addRing(center: foot, radius: length * 0.5, color: color)
        }

        // Outlines of every detected plane, so it's obvious what the app has
        // actually found versus what you can see.
        for plane in planes {
            addPlaneOutline(plane, color: SIMD4(0.5, 0.9, 1.0, alpha * 0.5))
        }
    }

    /// Highest plane below the splat whose outline contains it horizontally.
    ///
    /// If none does, falls back to the highest plane below regardless of
    /// extent: ARKit planes start small and grow, and a drop line that
    /// vanishes whenever the splat drifts past a partial floor edge is worse
    /// than one that lands slightly off the detected patch.
    private func supportingPlaneHeight(below point: SIMD3<Float>,
                                       planes: [DetectedPlane]) -> Float? {
        var containing: Float?
        var anyBelow: Float?
        for plane in planes {
            let height = plane.transform.columns.3.y
            guard height < point.y else { continue }
            anyBelow = max(anyBelow ?? height, height)
            let local = (simd_inverse(plane.transform) * SIMD4<Float>(point, 1)).xyz
            if Self.convexOutline(plane.outline, contains: SIMD2(local.x, local.z)) {
                containing = max(containing ?? height, height)
            }
        }
        return containing ?? anyBelow
    }

    /// `outline` is convex (ARKit's boundary is a hull; the fallback is a
    /// rectangle), so the point is inside when it sits on the same side of
    /// every edge. Checking for a consistent sign rather than a specific one
    /// keeps this independent of winding order.
    private static func convexOutline(_ outline: [SIMD2<Float>], contains point: SIMD2<Float>) -> Bool {
        guard outline.count >= 3 else { return false }
        var sawPositive = false
        var sawNegative = false
        for index in outline.indices {
            let a = outline[index]
            let b = outline[(index + 1) % outline.count]
            let edge = b - a
            let toPoint = point - a
            let cross = edge.x * toPoint.y - edge.y * toPoint.x
            if cross > 0 { sawPositive = true } else if cross < 0 { sawNegative = true }
            if sawPositive && sawNegative { return false }
        }
        return true
    }

    /// Notches at fixed real-world intervals, every `majorEvery`-th one longer.
    ///
    /// This is the whole point of the ruler: the splat's units are arbitrary,
    /// but these marks are meters, so stepping sideways and watching how many
    /// notches go by tells you how big the splat actually is.
    private func addTicks(center: SIMD3<Float>,
                          direction: SIMD3<Float>,
                          tickDirection: SIMD3<Float>,
                          length: Float,
                          ruler: RulerScale,
                          color: SIMD4<Float>) {
        guard ruler.spacing > 0, ruler.spacing.isFinite else { return }
        let count = Int(length / ruler.spacing)
        guard count > 0 else { return }

        // Cap the notch size so a coarse ruler doesn't sprout marks longer than
        // the bar they sit on.
        let maximumTick = length * 0.2
        let minor = min(ruler.spacing * Constants.minorTickFraction, maximumTick)
        let major = min(ruler.spacing * Constants.majorTickFraction, maximumTick)

        for step in 1...count {
            let isMajor = ruler.majorEvery > 0 && step % ruler.majorEvery == 0
            let half = tickDirection * (isMajor ? major : minor)
            let offset = direction * (Float(step) * ruler.spacing)
            for side in [offset, -offset] {
                addLine(from: center + side - half, to: center + side + half, color: color)
            }
        }
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

    /// Traces the plane's real outline where ARKit supplied one, falling back to
    /// its bounding rectangle. The two look very different in a room: the hull
    /// follows the table, the rectangle floats past its corners.
    private func addPlaneOutline(_ plane: DetectedPlane, color: SIMD4<Float>) {
        let corners = plane.outline.map { local -> SIMD3<Float> in
            (plane.transform * SIMD4<Float>(local.x, 0, local.y, 1)).xyz
        }
        guard corners.count >= 3 else { return }
        for i in corners.indices {
            addLine(from: corners[i], to: corners[(i + 1) % corners.count], color: color)
        }
    }

    private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }
}
