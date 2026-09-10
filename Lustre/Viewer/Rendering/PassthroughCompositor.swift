//
//  PassthroughCompositor.swift
//  Lustre
//
//  Offscreen splat target plus the fullscreen pass that combines it with the
//  camera image, optionally hiding the parts of the splat that sit behind a
//  detected real-world surface.
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

/// How the composite pass should hide splats behind real surfaces.
///
/// `nearZ`/`farZ` must match the projection the splats and the occluders were
/// rendered with — the shader uses them to turn both depth buffers back into
/// meters, which is the only way the bias below means anything physical.
struct OcclusionSettings {
    var nearZ: Float
    var farZ: Float

    /// How far behind a surface a splat must be before it starts to be hidden.
    /// Absorbs plane-estimate error: ARKit's plane sits within a couple of
    /// centimeters of the real one, and without this a splat resting on a table
    /// flickers against the table's own plane.
    var bias: Float = 0.03

    /// Distance over which occlusion ramps from none to full, so the boundary
    /// isn't a hard stair-step across a soft cloud.
    var feather: Float = 0.06
}

@MainActor
final class PassthroughCompositor {

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Lustre",
                                    category: "PassthroughCompositor")

    /// Mirrors the shader's `PassthroughUniforms`. `float3x3` is 48 bytes in
    /// MSL (three 16-byte columns), which `simd_float3x3` matches; the trailing
    /// scalars are padded explicitly so both sides agree on the size.
    private struct Uniforms {
        var displayTransform: simd_float3x3
        var isFullRange: UInt32
        var occlusionEnabled: UInt32
        var nearZ: Float
        var farZ: Float
        var occlusionBias: Float
        var occlusionFeather: Float
        var padding0: UInt32 = 0
        var padding1: UInt32 = 0
    }

    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState

    private(set) var splatColorTexture: MTLTexture?
    private(set) var splatDepthTexture: MTLTexture?
    /// Only allocated while occlusion is on — another full-resolution depth
    /// target is ~8 MB that a black background has no use for.
    private(set) var occluderDepthTexture: MTLTexture?
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
                        depthFormat: MTLPixelFormat,
                        includesOccluder: Bool) -> Bool {
        guard size.x > 0, size.y > 0 else { return false }
        if size != allocatedSize { releaseTargets() }

        if splatColorTexture == nil || splatDepthTexture == nil {
            let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat,
                                                                 width: size.x,
                                                                 height: size.y,
                                                                 mipmapped: false)
            color.usage = [.renderTarget, .shaderRead]
            color.storageMode = .private

            guard let colorTexture = device.makeTexture(descriptor: color),
                  // The splat pass's depth output is what the occlusion test
                  // compares against, so it has to be readable, not just a
                  // render target.
                  let depthTexture = makeDepthTexture(size: size, format: depthFormat)
            else {
                Self.log.error("Couldn't allocate offscreen passthrough targets at \(size.x)×\(size.y)")
                releaseTargets()
                return false
            }
            colorTexture.label = "Splat color (offscreen)"
            depthTexture.label = "Splat depth (offscreen)"
            splatColorTexture = colorTexture
            splatDepthTexture = depthTexture
        }

        if includesOccluder {
            if occluderDepthTexture == nil {
                guard let occluder = makeDepthTexture(size: size, format: depthFormat) else {
                    Self.log.error("Couldn't allocate the occluder depth target")
                    // Not fatal: passthrough still works, just without occlusion.
                    occluderDepthTexture = nil
                    allocatedSize = size
                    return true
                }
                occluder.label = "Occluder depth"
                occluderDepthTexture = occluder
            }
        } else {
            occluderDepthTexture = nil
        }

        allocatedSize = size
        return true
    }

    /// Deliberately `.private`, not `.memoryless`: these are read in a later
    /// render pass, which a memoryless attachment cannot survive.
    private func makeDepthTexture(size: SIMD2<Int>, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                                                                  width: size.x,
                                                                  height: size.y,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    /// Called on toggle-off and on memory warning — this is the single largest
    /// discretionary allocation the Viewer makes.
    func releaseTargets() {
        splatColorTexture = nil
        splatDepthTexture = nil
        occluderDepthTexture = nil
        allocatedSize = .zero
    }

    // MARK: - Composite

    /// Draws camera + splats into `target`. Returns false if it couldn't encode,
    /// so the caller can drop the frame rather than present a blank drawable.
    ///
    /// - Parameter occlusion: nil leaves every splat visible. Non-nil requires
    ///   that `occluderDepthTexture` was rendered into this same command buffer
    ///   first.
    func composite(cameraFrame: CameraFrame,
                   occlusion: OcclusionSettings?,
                   into target: MTLTexture,
                   commandBuffer: MTLCommandBuffer) -> Bool {
        guard let splatColorTexture, let splatDepthTexture else { return false }

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
        encoder.setFragmentTexture(splatDepthTexture, index: 3)

        let settings = occluderDepthTexture == nil ? nil : occlusion
        // Metal requires every texture the shader declares to be bound, even on
        // the branch that never samples it.
        encoder.setFragmentTexture(occluderDepthTexture ?? splatDepthTexture, index: 4)

        var uniforms = Uniforms(displayTransform: cameraFrame.displayTransform,
                                isFullRange: cameraFrame.isFullRange ? 1 : 0,
                                occlusionEnabled: settings == nil ? 0 : 1,
                                nearZ: settings?.nearZ ?? 0,
                                farZ: settings?.farZ ?? 1,
                                occlusionBias: settings?.bias ?? 0,
                                occlusionFeather: max(settings?.feather ?? 1, 1e-4))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }
}
