//
//  SurfaceProvider.swift
//  Lustre
//
//  Plane detection, tap-to-place anchoring, and the surfaces the placement
//  gizmo draws onto.
//
//  Same seam as `PoseProvider` and `CameraFrameSource`: no ARKit types cross
//  this boundary, so `SimulatedPoseProvider` can supply a synthetic floor and
//  the whole placement flow stays exercisable in the simulator.
//

import Foundation
import simd

/// A flat surface found in the world.
struct DetectedPlane: Equatable, Identifiable {
    let id: UUID
    /// Plane center in world space, +Y along the plane normal.
    var transform: simd_float4x4
    /// Width and depth in meters, in the plane's own axes.
    var extent: SIMD2<Float>

    /// Convex outline in the plane's local XZ, relative to `transform`.
    ///
    /// Empty means "no better information than the extent", and callers fall
    /// back to the rectangle. It matters for occlusion: a real table masked by
    /// its bounding rectangle cuts a hard rectangular hole out of the splat in
    /// mid-air, which reads as a bug rather than as a table.
    var boundary: [SIMD2<Float>] = []

    /// The outline to draw or rasterize, in the plane's local XZ.
    var outline: [SIMD2<Float>] {
        guard boundary.count >= 3 else {
            let halfWidth = extent.x / 2
            let halfDepth = extent.y / 2
            return [SIMD2(-halfWidth, -halfDepth), SIMD2(halfWidth, -halfDepth),
                    SIMD2(halfWidth, halfDepth), SIMD2(-halfWidth, halfDepth)]
        }
        return boundary
    }
}

/// Where the splat would land if placed right now.
struct PlacementCandidate: Equatable {
    var transform: simd_float4x4
    /// True when this came from a real detected surface. False means it's an
    /// estimate a fixed distance ahead, which the UI should present as "no
    /// surface found" rather than pretending it's grounded.
    var isOnSurface: Bool
}

@MainActor
protocol SurfaceProvider: AnyObject {
    /// Plane detection is expensive, so it's opt-in and must genuinely stop
    /// the underlying work when set false — not just hide the results.
    var isSurfaceDetectionEnabled: Bool { get set }

    var detectedPlanes: [DetectedPlane] { get }

    /// Raycast from the center of the screen. Nil before tracking is ready.
    var placementCandidate: PlacementCandidate? { get }

    /// Anchors the splat so the platform can correct it as tracking improves.
    /// This is the drift fix: a hardcoded world transform doesn't move when
    /// ARKit refines its map, so the splat appears to slide.
    func makeAnchor(at transform: simd_float4x4) -> UUID?

    /// The anchor's current, possibly refined, transform. Re-read every frame.
    func anchorTransform(for id: UUID) -> simd_float4x4?

    func removeAnchor(_ id: UUID)
}
