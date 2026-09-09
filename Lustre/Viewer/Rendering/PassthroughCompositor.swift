//
//  PassthroughCompositor.swift
//  Lustre
//
//  Offscreen splat target plus the fullscreen pass that combines it with the
//  camera image.
//
//  Exists because `MetalSplatter.SplatRenderer.render` hardcodes
//  `colorAttachments[0].loadAction = .clear`, so it always wipes whatever is
//  already in the color texture. Splats therefore render offscreen and this
//  type composites. See `Lustre/Viewer/INTEGRATION.md` §3.
//

import Foundation
import Metal
import os
import simd

@MainActor
final class PassthroughCompositor {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lustre",
                                    category: "PassthroughCompositor")

    /// Mirrors what the shader's `PassthroughUniforms` expects. `float3x3` is
    /// 48 bytes in MSL (three 16-byte columns), which `simd_float3x3` matches.
    private struct Uniforms {
        var displayTransform: simd_float3x3
        var isFullRange: UInt32
        // Explicit tail padding to a 16-byte multiple, so the Swift and MSL
        // layouts agree regardless of how the compiler pads the struct.
        var padding: SIMD3<UInt32> = .zero
    }

    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState

    private(set) var splatColorTexture: MTLTexture?
    private(set) var splatDepthTexture: MTLTexture?
    private var allocatedSize: SIMD2<Int> = .zero

    /// - Parameter colorFormat: must match the format the library renderer was
    ///   built with, since pass 1 renders into `splatColorTexture` using the
    ///   library's own pipeline state.
    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        self.device = device
        do {
            let library = try device.makeDefaultLibrary(bundle: .main)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Passthrough composite"
            descriptor.vertexFunction = library.makeFunction(name: "passthroughVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "passthroughFragment")
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            // The shader returns an opaque, fully composited pixel — no blending.
            descriptor.colorAttachments[0].isBlendingEnabled = false
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Self.log.error("Couldn't build the passthrough pipeline: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Offscreen targets

    /// Allocates the offscreen targets, reusing them unless the size changed.
    ///
    /// Only called while passthrough is active, so the ~24 MB at phone
    /// resolution isn't held when the background is black.
    func prepareTargets(size: SIMD2<Int>,
                        colorFormat: MTLPixelFormat,
                        depthFormat: MTLPixelFormat) -> Bool {
        guard size.x > 0, size.y > 0 else { return false }
        if size == allocatedSize, splatColorTexture != nil, splatDepthTexture != nil {
            return true
        }

        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat,
                                                             width: size.x,
                                                             height: size.y,
                                                             mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private

        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: depthFormat,
                                                             width: size.x,
                                                             height: size.y,
                                                             mipmapped: false)
        depth.usage = [.renderTarget]
        // Deliberately .private, not .memoryless: the library's device pipeline
        // (useMultiStagePipeline) has never run, and if it touches depth across
        // encoder boundaries a memoryless attachment breaks in a way no
        // simulator run would reveal. Revisit only after profiling on hardware.
        depth.storageMode = .private

        guard let colorTexture = device.makeTexture(descriptor: color),
              let depthTexture = device.makeTexture(descriptor: depth) else {
            Self.log.error("Couldn't allocate offscreen passthrough targets at \(size.x)×\(size.y)")
            releaseTargets()
            return false
        }
        colorTexture.label = "Splat color (offscreen)"
        depthTexture.label = "Splat depth (offscreen)"
        splatColorTexture = colorTexture
        splatDepthTexture = depthTexture
        allocatedSize = size
        return true
    }

    /// Called on toggle-off and on memory warning — this is the single largest
    /// discretionary allocation the Viewer makes.
    func releaseTargets() {
        splatColorTexture = nil
        splatDepthTexture = nil
        allocatedSize = .zero
    }

    // MARK: - Composite

    /// Draws camera + splats into `target`. Returns false if it couldn't encode,
    /// so the caller can drop the frame rather than present a blank drawable.
    func composite(cameraFrame: CameraFrame,
                   into target: MTLTexture,
                   commandBuffer: MTLCommandBuffer) -> Bool {
        guard let splatColorTexture else { return false }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        // Every pixel is written by the fullscreen triangle, so there's nothing
        // to preserve and nothing to clear.
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.label = "Passthrough composite"
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(splatColorTexture, index: 0)
        encoder.setFragmentTexture(cameraFrame.luma, index: 1)
        encoder.setFragmentTexture(cameraFrame.chroma, index: 2)

        var uniforms = Uniforms(displayTransform: cameraFrame.displayTransform,
                                isFullRange: cameraFrame.isFullRange ? 1 : 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}
