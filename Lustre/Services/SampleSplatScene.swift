//
//  SampleSplatScene.swift
//  Lustre
//
//  A procedurally generated room, so the Viewer has something to render
//  before the Library exists and without committing a large binary asset to
//  the repo. Build order step 1 calls for "hardcode a sample splat, see it
//  render" — this is that, generated rather than bundled.
//

import Foundation
import simd
import SplatIO

nonisolated enum SampleSplatScene {

    /// Half-width of the room, in meters.
    private static let roomExtent: Float = 3.0
    /// Distance between splat centers on the room surfaces.
    private static let spacing: Float = 0.14
    /// Floor height relative to the origin, in meters.
    private static let floorY: Float = -1.5

    /// A small room with a checkered floor, tinted walls, and a cube in the
    /// middle — enough spatial structure that walking around it reads as
    /// movement through a place rather than orbiting a blob.
    static func generate() -> [SplatPoint] {
        var points: [SplatPoint] = []
        points.reserveCapacity(20_000)

        let steps = Int((roomExtent * 2) / spacing)
        let ceilingY = floorY + roomExtent * 2

        for i in 0...steps {
            for j in 0...steps {
                let u = -roomExtent + Float(i) * spacing
                let v = -roomExtent + Float(j) * spacing

                // Floor: a checkerboard so motion is legible underfoot.
                let isDarkTile = ((i / 4) + (j / 4)) % 2 == 0
                let tile: SIMD3<Float> = isDarkTile ? [0.22, 0.23, 0.26] : [0.78, 0.77, 0.74]
                points.append(splat(at: [u, floorY, v], color: tile))

                // Walls, each a different hue so orientation is obvious.
                points.append(splat(at: [u, floorY + Float(j) * spacing, -roomExtent],
                                    color: [0.30, 0.42, 0.62]))
                points.append(splat(at: [u, floorY + Float(j) * spacing, roomExtent],
                                    color: [0.62, 0.38, 0.34]))
                points.append(splat(at: [-roomExtent, floorY + Float(j) * spacing, u],
                                    color: [0.34, 0.55, 0.44]))
                points.append(splat(at: [roomExtent, floorY + Float(j) * spacing, u],
                                    color: [0.60, 0.56, 0.34]))

                // Ceiling, dimmer than the floor so up and down don't read alike.
                points.append(splat(at: [u, ceilingY, v], color: [0.16, 0.16, 0.18]))
            }
        }

        points.append(contentsOf: centerCube())
        return points
    }

    /// A solid cube floating at eye level, to give the room a subject.
    private static func centerCube() -> [SplatPoint] {
        var points: [SplatPoint] = []
        let half: Float = 0.4
        let cubeSpacing: Float = 0.05
        let steps = Int((half * 2) / cubeSpacing)
        let center = SIMD3<Float>(0, floorY + 1.4, 0)

        for i in 0...steps {
            for j in 0...steps {
                for k in 0...steps {
                    // Hollow it out; interior splats are never visible anyway.
                    let onSurface = i == 0 || i == steps
                        || j == 0 || j == steps
                        || k == 0 || k == steps
                    guard onSurface else { continue }

                    let offset = SIMD3<Float>(-half + Float(i) * cubeSpacing,
                                              -half + Float(j) * cubeSpacing,
                                              -half + Float(k) * cubeSpacing)
                    // Tint by position so each face is distinguishable.
                    let color = (offset + half) / (half * 2) * 0.7 + 0.2
                    points.append(splat(at: center + offset, color: color, radius: 0.03))
                }
            }
        }
        return points
    }

    private static func splat(at position: SIMD3<Float>,
                              color: SIMD3<Float>,
                              radius: Float = 0.075) -> SplatPoint {
        SplatPoint(position: position,
                   color: .sphericalHarmonicFloat([sh0(for: color)]),
                   opacity: .linearFloat(0.95),
                   scale: .linearFloat(SIMD3(repeating: radius)),
                   rotation: simd_quatf(angle: 0, axis: [0, 1, 0]))
    }

    /// Converts an sRGB color in 0...1 to the degree-0 spherical harmonic
    /// coefficient MetalSplatter expects. Mirrors `SplatPoint.Color`'s own
    /// conversion, which isn't public.
    private static func sh0(for srgb: SIMD3<Float>) -> SIMD3<Float> {
        let shC0: Float = 0.28209479177387814
        return (srgb - 0.5) / shC0
    }
}
