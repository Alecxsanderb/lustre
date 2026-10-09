//
//  CaptureSpikeModel.swift
//  Lustre
//
//  THROWAWAY (Capture commit 0). Main-actor state for the spike screen: the
//  format list, preset availability, picker selections, and the engine's
//  throttled stats.
//

import ARKit
import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

@Observable
final class CaptureSpikeModel {

    let isSupported = ARWorldTrackingConfiguration.isSupported

    /// Snapshot of `supportedVideoFormats`, in ARKit's order.
    let formats: [ARConfiguration.VideoFormat]
    let formatListText: String
    let availability: [SpikePreset: SpikeFormatChoice]

    var preset: SpikePreset = .hd30 {
        didSet { if preset != oldValue { runSession(resetTracking: true) } }
    }
    var exposure: SpikeExposureMode = .auto
    var lighting: SpikeLighting = .bright

    private(set) var stats = SpikeLiveStats()

    @ObservationIgnored private var engine: CaptureSpikeEngine?
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var isSessionRunning = false

    init() {
        let formats = ARWorldTrackingConfiguration.isSupported ? ARWorldTrackingConfiguration.supportedVideoFormats : []
        self.formats = formats
        self.formatListText = Self.describeFormats(formats)
        let candidates = formats.map { Self.candidate($0) }
        var availability: [SpikePreset: SpikeFormatChoice] = [:]
        for preset in SpikePreset.allCases {
            availability[preset] = SpikeFormatSelection.choose(preset, from: candidates)
        }
        self.availability = availability
        // Start on the first preset this device can actually run.
        if availability[.hd30]?.isAvailable != true,
           let first = SpikePreset.allCases.first(where: { availability[$0]?.isAvailable == true }) {
            preset = first
        }
    }

    /// Created on first use and only when ARKit is supported.
    func sessionForPreview() -> ARSession? {
        engineIfSupported()?.session
    }

    func previewAttached() {
        engine?.attachDelegate()
    }

    // MARK: - Lifecycle

    func appear() {
        isOnScreen = true
        runSession(resetTracking: true)
    }

    func disappear() {
        isOnScreen = false
        suspend()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            suspend()
        case .active:
            if isOnScreen && !isSessionRunning { runSession(resetTracking: false) }
        default:
            break
        }
    }

    private func suspend() {
        guard isSessionRunning else { return }
        isSessionRunning = false
        engine?.pause()
    }

    private func runSession(resetTracking: Bool) {
        guard isOnScreen, let engine = engineIfSupported(),
              case .available(let index) = availability[preset] else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        configuration.isAutoFocusEnabled = true
        configuration.videoFormat = formats[index]
        configuration.videoHDRAllowed = false
        engine.run(configuration, preset: preset, resetTracking: resetTracking)
        isSessionRunning = true
    }

    private func engineIfSupported() -> CaptureSpikeEngine? {
        guard isSupported else { return nil }
        if let engine { return engine }
        let made = CaptureSpikeEngine { [weak self] stats in
            self?.stats = stats
        }
        engine = made
        return made
    }

    // MARK: - Formats

    nonisolated private static func candidate(_ format: ARConfiguration.VideoFormat) -> SpikeFormatCandidate {
        SpikeFormatCandidate(width: Int(format.imageResolution.width),
                             height: Int(format.imageResolution.height),
                             framesPerSecond: format.framesPerSecond,
                             isWideBackCamera: format.captureDeviceType == .builtInWideAngleCamera
                                && format.captureDevicePosition == .back)
    }

    nonisolated static func describe(_ format: ARConfiguration.VideoFormat) -> String {
        let camera: String = switch format.captureDeviceType {
        case .builtInWideAngleCamera: "wide"
        case .builtInUltraWideCamera: "ultra-wide"
        case .builtInTelephotoCamera: "telephoto"
        case .builtInTrueDepthCamera: "TrueDepth"
        default: format.captureDeviceType.rawValue
        }
        let position: String = switch format.captureDevicePosition {
        case .back: "back"
        case .front: "front"
        default: "unspecified"
        }
        return "\(Int(format.imageResolution.width))×\(Int(format.imageResolution.height)) @\(format.framesPerSecond) fps, "
            + "\(position) \(camera), HDR \(format.isVideoHDRSupported ? "yes" : "no"), "
            + "hi-res-capture recommended \(format.isRecommendedForHighResolutionFrameCapturing ? "yes" : "no")"
    }

    nonisolated private static func describeFormats(_ formats: [ARConfiguration.VideoFormat]) -> String {
        guard !formats.isEmpty else { return "No formats (ARKit unsupported)." }
        var lines = formats.enumerated().map { "[\($0.offset)] \(describe($0.element))" }
        let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution
        let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing
        lines.append("recommendedVideoFormatFor4KResolution: \(fourK.map { describe($0) } ?? "nil")")
        lines.append("recommendedVideoFormatForHighResolutionFrameCapturing: \(hiRes.map { describe($0) } ?? "nil")")
        return lines.joined(separator: "\n")
    }
}
