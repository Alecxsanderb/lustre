//
//  TestPatternCameraSource.swift
//  Lustre
//
//  A synthetic camera feed, so the passthrough composite path can be seen and
//  debugged without a device.
//
//  The real source (`ARKitPoseProvider`) can't run in the simulator, which
//  would otherwise leave the whole compositor — premultiplied alpha, sRGB
//  linearization, the UV transform — unverifiable until someone runs it on an
//  iPhone. This exercises everything except the ARKit plumbing.
//

import Foundation
import Metal
import simd

@MainActor
final class TestPatternCameraSource: CameraFrameSource {

    private let device: MTLDevice
    private var luma: MTLTexture?
    private var chroma: MTLTexture?

    /// Deliberately not a 16:9 camera resolution — a square source makes an
    /// incorrect display transform obvious as a stretch rather than a subtle crop.
    private let size = 256

    init(device: MTLDevice) {
        self.device = device
    }

    var isCameraFrameAvailable: Bool { true }

    func currentCameraFrame(viewportSize: CGSize) -> CameraFrame? {
        if luma == nil || chroma == nil { buildTextures() }
        guard let luma, let chroma else { return nil }
        return CameraFrame(luma: luma,
                           chroma: chroma,
                           // Identity: the pattern is authored in view space,
                           // so any stretch or rotation on screen is a bug in
                           // the compositor rather than in this source.
                           displayTransform: matrix_identity_float3x3,
                           isFullRange: true)
    }

    /// Colour bars over a luma ramp: the bars make the chroma path and the
    /// YCbCr matrix visible, the ramp makes a missing sRGB linearization show
    /// up as a bend in the gradient.
    private func buildTextures() {
        let lumaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        let chromaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg8Unorm, width: size / 2, height: size / 2, mipmapped: false)

        guard let lumaTexture = device.makeTexture(descriptor: lumaDescriptor),
              let chromaTexture = device.makeTexture(descriptor: chromaDescriptor) else { return }

        var lumaBytes = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                lumaBytes[y * size + x] = UInt8(x * 255 / (size - 1))
            }
        }
        lumaTexture.replace(region: MTLRegionMake2D(0, 0, size, size),
                            mipmapLevel: 0,
                            withBytes: lumaBytes,
                            bytesPerRow: size)

        let half = size / 2
        var chromaBytes = [UInt8](repeating: 128, count: half * half * 2)
        for y in 0..<half {
            for x in 0..<half {
                let index = (y * half + x) * 2
                // Sweep Cb across and Cr down, so every hue appears somewhere.
                chromaBytes[index] = UInt8(x * 255 / (half - 1))
                chromaBytes[index + 1] = UInt8(y * 255 / (half - 1))
            }
        }
        chromaTexture.replace(region: MTLRegionMake2D(0, 0, half, half),
                              mipmapLevel: 0,
                              withBytes: chromaBytes,
                              bytesPerRow: half * 2)

        luma = lumaTexture
        chroma = chromaTexture
    }
}
