//
//  MatrixMath.swift
//  Lustre
//
//  Shared matrix helpers. Adapted from Apple's Metal sample code.
//  Lives in Core so both Viewer and (later) Capture can use it without
//  reaching across feature folders.
//

import simd

nonisolated extension SIMD4 where Scalar == Float {
    /// The first three components, for pulling a translation out of a matrix column.
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

nonisolated func matrix4x4_rotation(radians: Float, axis: SIMD3<Float>) -> matrix_float4x4 {
    let unitAxis = normalize(axis)
    let ct = cosf(radians)
    let st = sinf(radians)
    let ci = 1 - ct
    let x = unitAxis.x, y = unitAxis.y, z = unitAxis.z
    return matrix_float4x4(columns: (SIMD4<Float>(    ct + x * x * ci, y * x * ci + z * st, z * x * ci - y * st, 0),
                                     SIMD4<Float>(x * y * ci - z * st,     ct + y * y * ci, z * y * ci + x * st, 0),
                                     SIMD4<Float>(x * z * ci + y * st, y * z * ci - x * st,     ct + z * z * ci, 0),
                                     SIMD4<Float>(                  0,                   0,                   0, 1)))
}

nonisolated func matrix4x4_translation(_ x: Float, _ y: Float, _ z: Float) -> matrix_float4x4 {
    matrix_float4x4(columns: (SIMD4<Float>(1, 0, 0, 0),
                              SIMD4<Float>(0, 1, 0, 0),
                              SIMD4<Float>(0, 0, 1, 0),
                              SIMD4<Float>(x, y, z, 1)))
}

nonisolated func matrix4x4_translation(_ t: SIMD3<Float>) -> matrix_float4x4 {
    matrix4x4_translation(t.x, t.y, t.z)
}

nonisolated func matrix4x4_scale(_ s: Float) -> matrix_float4x4 {
    matrix_float4x4(columns: (SIMD4<Float>(s, 0, 0, 0),
                              SIMD4<Float>(0, s, 0, 0),
                              SIMD4<Float>(0, 0, s, 0),
                              SIMD4<Float>(0, 0, 0, 1)))
}

/// Right-handed perspective projection matching Metal's [0, 1] depth range.
///
/// Used when the pose provider doesn't supply its own projection. On device,
/// `ARKitPoseProvider` overrides this with the real camera intrinsics so the
/// splat lines up with the physical world.
nonisolated func perspectiveProjection(fovyRadians fovy: Float,
                           aspectRatio: Float,
                           nearZ: Float,
                           farZ: Float) -> matrix_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)
    return matrix_float4x4(columns: (SIMD4<Float>(xs,  0,  0,          0),
                                     SIMD4<Float>( 0, ys,  0,          0),
                                     SIMD4<Float>( 0,  0, zs,         -1),
                                     SIMD4<Float>( 0,  0, zs * nearZ,  0)))
}
