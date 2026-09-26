//
//  ThumbnailFraming.swift
//  Lustre
//
//  Where the thumbnail camera sits. Pure math, so it's testable without Metal
//  and lives in Core next to the model transform it has to agree with.
//
//  v1 is an exterior 3/4 view: the camera on the +Z side of the splat looking
//  toward -Z, which is how a splat first faces you in the Viewer at yaw 0,
//  raised ~20° so the top reads. Interior captures (rooms) will look like a
//  shell from outside; accepted for v1.
//

import simd

nonisolated enum ThumbnailFraming {

    /// Library tiles are 4:3.
    static let defaultAspect: Float = 4.0 / 3.0

    /// Close to the Viewer's simulated camera (65°), slightly narrower so the
    /// perspective doesn't exaggerate a small tile.
    static let defaultFovY: Float = 50 * .pi / 180

    static let elevation: Float = 20 * .pi / 180

    /// Breathing room around the bounding sphere.
    static let margin: Float = 1.1

    /// Radius floor, in world units, so a single-point or empty-extent cloud
    /// still gets a finite camera rather than one sitting on its target.
    static let minimumRadius: Float = 1e-3

    /// The transform the Viewer applies to a library file when it opens:
    /// recentred on its bounds, with the up-calibration flip (always on for
    /// library files). Scale is left at 1 because the camera fits whatever
    /// size it's given, so uniform scale doesn't change the picture.
    static func libraryModelMatrix(for bounds: SplatBounds) -> simd_float4x4 {
        SplatModelTransform.matrix(pivot: bounds.center,
                                   appliesUpCalibration: true,
                                   scale: SplatScale.authored)
    }

    /// Axis-aligned bounds of `bounds` after `matrix`. Transforms all eight
    /// corners, so it's correct for rotations too.
    static func transformed(_ bounds: SplatBounds, by matrix: simd_float4x4) -> SplatBounds {
        var minimum = SIMD3<Float>(repeating: .infinity)
        var maximum = SIMD3<Float>(repeating: -.infinity)
        for corner in corners(of: bounds) {
            let point = (matrix * SIMD4(corner, 1)).xyz
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        return SplatBounds(minimum: minimum, maximum: maximum)
    }

    static func corners(of bounds: SplatBounds) -> [SIMD3<Float>] {
        let lo = bounds.minimum, hi = bounds.maximum
        return [SIMD3(lo.x, lo.y, lo.z), SIMD3(hi.x, lo.y, lo.z),
                SIMD3(lo.x, hi.y, lo.z), SIMD3(hi.x, hi.y, lo.z),
                SIMD3(lo.x, lo.y, hi.z), SIMD3(hi.x, lo.y, hi.z),
                SIMD3(lo.x, hi.y, hi.z), SIMD3(hi.x, hi.y, hi.z)]
    }

    /// View and projection that fit `bounds` (world space, i.e. after the
    /// model transform) in frame.
    ///
    /// Fits the bounding sphere rather than the box so the distance doesn't
    /// depend on the view direction, against the tighter of the vertical and
    /// horizontal FOV so it fits both ways at any aspect.
    static func camera(for bounds: SplatBounds,
                       aspect: Float = defaultAspect,
                       fovY: Float = defaultFovY) -> (view: simd_float4x4, projection: simd_float4x4) {
        let center = isFinite(bounds.center) ? bounds.center : .zero
        let halfDiagonal = simd_length(bounds.extent) / 2
        let radius = max(halfDiagonal.isFinite ? halfDiagonal : 0, minimumRadius) * margin

        let safeAspect = aspect.isFinite && aspect > 0 ? aspect : defaultAspect
        let safeFovY = fovY.isFinite && fovY > 0 && fovY < .pi ? fovY : defaultFovY
        let halfFovY = safeFovY / 2
        let halfFovX = atanf(tanf(halfFovY) * safeAspect)
        let distance = radius / sinf(min(halfFovY, halfFovX))

        let direction = SIMD3<Float>(0, sinf(elevation), cosf(elevation))
        let eye = center + direction * distance

        // The sphere spans distance ± radius along the view axis. Floaters
        // outside the robust bounds get clipped, which is fine for a thumbnail.
        let nearZ = max(distance - radius, distance * 0.01)
        let farZ = distance + radius * 4

        return (view: lookAt(eye: eye, target: center),
                projection: perspectiveProjection(fovyRadians: safeFovY,
                                                  aspectRatio: safeAspect,
                                                  nearZ: nearZ,
                                                  farZ: farZ))
    }

    /// Right-handed view matrix looking from `eye` to `target` with world +Y
    /// up. The camera looks down its own -Z, matching `perspectiveProjection`.
    /// Safe only while the view direction isn't vertical, which a fixed 20°
    /// elevation guarantees.
    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        let back = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        let cameraToWorld = simd_float4x4(columns: (SIMD4(right, 0),
                                                    SIMD4(up, 0),
                                                    SIMD4(back, 0),
                                                    SIMD4(eye, 1)))
        return simd_inverse(cameraToWorld)
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}
