//
//  CaptureSpikeEngine.swift
//  Lustre
//
//  THROWAWAY (Capture commit 0). Owns the ARSession for the spike screen and
//  everything that touches frames. Device only: in the simulator ARKit is
//  unsupported and the screen never creates one of these.
//
//  Threading: ARKit delivers delegate callbacks on `queue`, and every public
//  method hops onto it, so all mutable state below is confined to that one
//  serial queue. That confinement (not the compiler) is what makes it safe,
//  hence `@unchecked Sendable`. `ARFrame` is never stored past the callback.
//

import ARKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import simd

nonisolated final class CaptureSpikeEngine: NSObject, ARSessionDelegate, @unchecked Sendable {

    let session = ARSession()

    private let queue = DispatchQueue(label: "com.alecborer.lustre.capture-spike", qos: .userInitiated)
    private let onStats: @MainActor @Sendable (SpikeLiveStats) -> Void

    // Everything below: `queue` only.
    private var preset: SpikePreset = .hd30
    private var trackingState = "not running"
    private var sessionError: String?
    private var lastStatsPush: Double = 0
    private var lastReadback: Double = 0
    private var latestReading: SpikeDeviceReading?
    private var sessionStartUptime = ProcessInfo.processInfo.systemUptime
    private var imageDescription = "—"

    /// - Parameter onStats: called on the main actor at ~4 Hz.
    init(onStats: @escaping @MainActor @Sendable (SpikeLiveStats) -> Void) {
        self.onStats = onStats
        super.init()
        attachDelegate()
    }

    /// Call again after handing `session` to an `ARView`, in case the view
    /// replaced the delegate.
    func attachDelegate() {
        session.delegateQueue = queue
        session.delegate = self
    }

    // MARK: - Control (any thread)

    func run(_ configuration: ARWorldTrackingConfiguration, preset: SpikePreset, resetTracking: Bool) {
        session.run(configuration, options: resetTracking ? [.resetTracking, .removeExistingAnchors] : [])
        queue.async {
            self.preset = preset
            self.sessionError = nil
            self.sessionStartUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    func pause() {
        session.pause()
        queue.async { self.trackingState = "paused" }
    }

    // MARK: - ARSessionDelegate (queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        if imageDescription == "—" {
            let image = frame.capturedImage
            imageDescription = "\(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)) "
                + SpikeRunNaming.fourCC(CVPixelBufferGetPixelFormatType(image))
        }
        if now - lastReadback >= 1 {
            lastReadback = now
            latestReading = readDevice(at: ProcessInfo.processInfo.systemUptime - sessionStartUptime)
        }
        if now - lastStatsPush >= 0.25 {
            lastStatsPush = now
            pushStats()
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingState = Self.describe(camera.trackingState)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionError = error.localizedDescription
        pushStats()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingState = "interrupted"
    }

    // MARK: - Device read-back (queue)

    private func readDevice(at time: Double) -> SpikeDeviceReading? {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return nil }
        let gains = device.deviceWhiteBalanceGains
        return SpikeDeviceReading(time: time,
                                  duration: device.exposureDuration.seconds,
                                  iso: device.iso,
                                  lensPosition: device.lensPosition,
                                  whiteBalanceGains: [gains.redGain, gains.greenGain, gains.blueGain],
                                  exposureMode: Self.describe(device.exposureMode),
                                  whiteBalanceMode: Self.describe(device.whiteBalanceMode),
                                  focusMode: Self.describe(device.focusMode))
    }

    // MARK: - Stats (queue)

    private func pushStats() {
        let stats = makeStats()
        let onStats = self.onStats
        Task { @MainActor in onStats(stats) }
    }

    private func makeStats() -> SpikeLiveStats {
        var stats = SpikeLiveStats()
        stats.trackingState = trackingState
        stats.sessionError = sessionError
        stats.reading = latestReading
        stats.image = imageDescription
        stats.thermal = Self.describe(ProcessInfo.processInfo.thermalState)
        return stats
    }

    // MARK: - Descriptions

    static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: "normal"
        case .notAvailable: "not available"
        case .limited(let reason):
            switch reason {
            case .initializing: "limited (initializing)"
            case .excessiveMotion: "limited (excessive motion)"
            case .insufficientFeatures: "limited (insufficient features)"
            case .relocalizing: "limited (relocalizing)"
            @unknown default: "limited (unknown)"
            }
        }
    }

    static func describe(_ mode: AVCaptureDevice.ExposureMode) -> String {
        switch mode {
        case .locked: "locked"
        case .autoExpose: "auto"
        case .continuousAutoExposure: "continuous"
        case .custom: "custom"
        @unknown default: "unknown"
        }
    }

    static func describe(_ mode: AVCaptureDevice.WhiteBalanceMode) -> String {
        switch mode {
        case .locked: "locked"
        case .autoWhiteBalance: "auto"
        case .continuousAutoWhiteBalance: "continuous"
        @unknown default: "unknown"
        }
    }

    static func describe(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode {
        case .locked: "locked"
        case .autoFocus: "auto"
        case .continuousAutoFocus: "continuous"
        @unknown default: "unknown"
        }
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Snapshot pushed to the UI. Plain values only.
nonisolated struct SpikeLiveStats: Equatable, Sendable {
    var trackingState = "—"
    var sessionError: String?
    var reading: SpikeDeviceReading?
    var image = "—"
    var thermal = "—"
}
