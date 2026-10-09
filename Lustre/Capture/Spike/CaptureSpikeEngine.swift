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

    // Exposure / white balance / focus locking.
    private enum LockPhase {
        case idle
        /// Put the device back on auto at the next frame, then meter.
        case pendingAutoReset
        /// Let auto exposure converge for this many frames before locking.
        case settling(framesLeft: Int)
        case held
    }
    private static let settleFrames = 30
    private var exposure: SpikeExposureMode = .auto
    private var lockPhase = LockPhase.idle
    private var lockTarget = SpikeLockTarget()
    private var appliedExposure: SpikeExposureSetting?
    private var lockNote = "not applied yet"
    /// True while recording: focus stays locked, including across re-locks.
    private var wantsFocusLock = false
    private var latestDeviations: [String] = []

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

    func run(_ configuration: ARWorldTrackingConfiguration, preset: SpikePreset,
             exposure: SpikeExposureMode, resetTracking: Bool) {
        session.run(configuration, options: resetTracking ? [.resetTracking, .removeExistingAnchors] : [])
        queue.async {
            self.preset = preset
            self.exposure = exposure
            self.sessionError = nil
            self.sessionStartUptime = ProcessInfo.processInfo.systemUptime
            // A (re)run can reconfigure the capture device, so lock again.
            self.requestLock()
        }
    }

    func setExposure(_ exposure: SpikeExposureMode) {
        queue.async {
            self.exposure = exposure
            self.requestLock()
        }
    }

    func pause() {
        session.pause()
        queue.async { self.trackingState = "paused" }
    }

    // MARK: - ARSessionDelegate (queue)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let now = frame.timestamp
        advanceLock()
        if imageDescription == "—" {
            let image = frame.capturedImage
            imageDescription = "\(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)) "
                + SpikeRunNaming.fourCC(CVPixelBufferGetPixelFormatType(image))
        }
        if now - lastReadback >= 1 {
            lastReadback = now
            latestReading = readDevice(at: ProcessInfo.processInfo.systemUptime - sessionStartUptime)
            if let reading = latestReading, case .held = lockPhase {
                latestDeviations = SpikeLockCheck.deviations(of: reading, from: lockTarget)
            } else {
                latestDeviations = []
            }
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

    func sessionInterruptionEnded(_ session: ARSession) {
        // ARKit may have reset the device while the camera was away.
        requestLock()
    }

    // MARK: - Locking (queue)

    private func requestLock() {
        lockPhase = .pendingAutoReset
        lockTarget.duration = nil
        lockTarget.iso = nil
        lockTarget.whiteBalanceGains = nil
        appliedExposure = nil
        lockNote = exposure == .auto ? "auto (ARKit)" : "metering…"
    }

    private func advanceLock() {
        switch lockPhase {
        case .idle, .held:
            break
        case .pendingAutoReset:
            resetToAuto()
            lockPhase = .settling(framesLeft: Self.settleFrames)
        case .settling(let framesLeft):
            if framesLeft > 1 {
                lockPhase = .settling(framesLeft: framesLeft - 1)
            } else {
                applyLock()
                lockPhase = .held
            }
        }
    }

    /// Runs `body` with the primary camera locked for configuration.
    @discardableResult
    private func configureDevice(_ body: (AVCaptureDevice) -> Void) -> Bool {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            lockNote = "configurableCaptureDeviceForPrimaryCamera is nil"
            return false
        }
        do {
            try device.lockForConfiguration()
        } catch {
            lockNote = "lockForConfiguration failed: \(error.localizedDescription)"
            return false
        }
        body(device)
        device.unlockForConfiguration()
        return true
    }

    /// Back to continuous auto so the next lock meters from a converged auto
    /// exposure rather than from a previous lock.
    private func resetToAuto() {
        configureDevice { device in
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if wantsFocusLock {
                lockFocus(device)
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
    }

    private func applyLock() {
        configureDevice { device in
            if let target = exposure.targetDuration {
                lockExposure(device, target: target)
                lockWhiteBalance(device)
            } else {
                lockNote = "auto (ARKit)"
            }
            if wantsFocusLock { lockFocus(device) }
        }
    }

    /// Device must be locked for configuration.
    private func lockExposure(_ device: AVCaptureDevice, target: Double) {
        guard device.isExposureModeSupported(.custom) else {
            lockNote = "custom exposure unsupported"
            return
        }
        let format = device.activeFormat
        let setting = SpikeExposureMath.compensate(
            currentISO: device.iso,
            currentDuration: device.exposureDuration.seconds,
            targetDuration: target,
            isoRange: format.minISO...format.maxISO,
            durationRange: format.minExposureDuration.seconds...format.maxExposureDuration.seconds)
        device.setExposureModeCustom(duration: CMTime(seconds: setting.duration, preferredTimescale: 1_000_000),
                                     iso: setting.iso, completionHandler: nil)
        appliedExposure = setting
        lockTarget.duration = setting.duration
        lockTarget.iso = setting.iso
        var note = String(format: "locked 1/%.0f s, ISO %.0f", 1 / setting.duration, setting.iso)
        if setting.isUnderexposed { note += " (underexposed: ISO at max)" }
        if setting.isOverexposed { note += " (overexposed: ISO at min)" }
        lockNote = note
    }

    private func lockWhiteBalance(_ device: AVCaptureDevice) {
        guard device.isWhiteBalanceModeSupported(.locked) else {
            lockNote += "; WB lock unsupported"
            return
        }
        let current = device.deviceWhiteBalanceGains
        let maxGain = device.maxWhiteBalanceGain
        func clamp(_ gain: Float) -> Float { min(max(gain, 1), maxGain) }
        let gains = AVCaptureDevice.WhiteBalanceGains(redGain: clamp(current.redGain),
                                                       greenGain: clamp(current.greenGain),
                                                       blueGain: clamp(current.blueGain))
        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        lockTarget.whiteBalanceGains = [gains.redGain, gains.greenGain, gains.blueGain]
    }

    private func lockFocus(_ device: AVCaptureDevice) {
        guard device.isFocusModeSupported(.locked) else { return }
        device.focusMode = .locked
        lockTarget.lensPosition = device.lensPosition
    }

    /// Focus lock for the take: intrinsics stay constant while recording.
    private func beginFocusLock() {
        wantsFocusLock = true
        configureDevice { lockFocus($0) }
    }

    private func endFocusLock() {
        wantsFocusLock = false
        lockTarget.lensPosition = nil
        configureDevice { device in
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        }
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
        stats.lockNote = lockNote
        stats.isUnderexposed = appliedExposure?.isUnderexposed ?? false
        stats.deviations = latestDeviations
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
    var lockNote = "—"
    var isUnderexposed = false
    /// Non-empty when the last read-back no longer matches the lock.
    var deviations: [String] = []
    var image = "—"
    var thermal = "—"
}
