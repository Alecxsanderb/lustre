//
//  Frustum.swift
//  Lustre
//
//  Six-plane view frustum extracted from a view-projection matrix, plus an
//  axis-aligned box test. Used to skip splat chunks that can't be on screen.
//

import Foundation
import simd

nonisolated struct Frustum: Equatable, Sendable {

    /// Inward-facing planes as `(a, b, c, d)`, where a point is inside when
    /// `a·x + b·y + c·z + d >= 0`. Order is left, right, bottom, top, near, far.
    let planes: [SIMD4<Float>]

    /// Extracts the planes from any matrix that maps points to clip space.
    ///
    /// Hand it `projection × view × model` and the resulting planes are in
    /// *model* space, which is what lets chunk bounds stay in the splat's own
    /// coordinates instead of being transformed every frame.
    ///
    /// Assumes Metal's clip volume: `-w <= x, y <= w` and `0 <= z <= w`. The
    /// near plane is therefore `z >= 0`, not `z >= -w` as it would be in GL.
    init(viewProjection matrix: simd_float4x4) {
        // simd is column-major and `clip = matrix * point`, so the dot products
        // that produce clip components are the matrix's *rows*.
        func row(_ index: Int) -> SIMD4<Float> {
            SIMD4(matrix.columns.0[index],
                  matrix.columns.1[index],
                  matrix.columns.2[index],
                  matrix.columns.3[index])
        }
        let x = row(0), y = row(1), z = row(2), w = row(3)

        planes = [
            Self.normalized(w + x),   // left:   x + w >= 0
            Self.normalized(w - x),   // right:  w - x >= 0
            Self.normalized(w + y),   // bottom
            Self.normalized(w - y),   // top
            Self.normalized(z),       // near:   z >= 0
            Self.normalized(w - z),   // far
        ]
    }

    /// Scaling a plane doesn't change which side a point is on, but it does
    /// change what `margin` means — normalizing is what makes the margin a
    /// distance rather than an arbitrary number.
    private static func normalized(_ plane: SIMD4<Float>) -> SIMD4<Float> {
        let length = simd_length(plane.xyz)
        guard length > 1e-9, length.isFinite else { return plane }
        return plane / length
    }

    /// Whether an axis-aligned box is at least partly inside.
    ///
    /// Conservative: a box straddling two planes' outside half-spaces without
    /// entering the frustum still reports true. That's the correct trade for
    /// culling, where a false positive costs a draw and a false negative
    /// makes geometry vanish.
    ///
    /// - Parameter margin: meters to grow the box by, in whatever units the
    ///   matrix's input space uses. A little slack keeps chunks from popping
    ///   at the screen edge.
    func intersects(minimum: SIMD3<Float>, maximum: SIMD3<Float>, margin: Float = 0) -> Bool {
        let low = minimum - SIMD3(repeating: margin)
        let high = maximum + SIMD3(repeating: margin)

        for plane in planes {
            let normal = plane.xyz
            // The corner furthest along the plane normal. If even that one is
            // behind the plane, every corner is.
            let positiveVertex = SIMD3(normal.x >= 0 ? high.x : low.x,
                                       normal.y >= 0 ? high.y : low.y,
                                       normal.z >= 0 ? high.z : low.z)
            if simd_dot(normal, positiveVertex) + plane.w < 0 {
                return false
            }
        }
        return true
    }
}
