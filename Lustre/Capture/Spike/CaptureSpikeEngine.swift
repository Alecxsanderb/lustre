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

    private var recording: SpikeRecording?

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

    /// Recording starts at the next frame. Focus locks now.
    func startRecording(_ request: SpikeRecordingRequest) {
        queue.async {
            guard self.recording == nil else { return }
            let recording = SpikeRecording(request: request, preset: self.preset, exposure: self.exposure,
                                           startUptime: ProcessInfo.processInfo.systemUptime)
            recording.trackingEvents.append(SpikeEvent(time: 0, value: self.trackingState))
            recording.lastThermal = ProcessInfo.processInfo.thermalState
            recording.thermalEvents.append(SpikeEvent(time: 0, value: Self.describe(recording.lastThermal)))
            self.recording = recording
            self.beginFocusLock()
            self.pushStats()
        }
    }

    /// Finishes the file, saves the report, and calls `completion` on the
    /// main actor. Safe to call with nothing recording (reports nil).
    func stopRecording(completion: @escaping @MainActor @Sendable (SpikeStopResult?) -> Void) {
        queue.async {
            guard let recording = self.recording else {
                Task { @MainActor in completion(nil) }
                return
            }
            self.recording = nil
            // Snapshot lock state before releasing focus for preview.
            let lockTarget = self.lockTarget
            let exposureSetting = self.appliedExposure
            let lockNote = self.lockNote
            self.endFocusLock()
            self.pushStats()

            let save: @Sendable (SpikeVideoWriter.Outcome) -> Void = { outcome in
                self.queue.async {
                    let result = self.saveReport(for: recording, outcome: outcome, lockTarget: lockTarget,
                                                 exposureSetting: exposureSetting, lockNote: lockNote)
                    Task { @MainActor in completion(result) }
                }
            }
            if let writer = recording.writer {
                writer.finish(completion: save)
            } else {
                save(.init(status: "not started", error: recording.writerSetupError ?? "no frames arrived"))
            }
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
        if let recording { record(frame, into: recording) }
        if now - lastReadback >= 1 {
            lastReadback = now
            readBack()
        }
        if now - lastStatsPush >= 0.25 {
            lastStatsPush = now
            pushStats()
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        trackingState = Self.describe(camera.trackingState)
        recording?.trackingEvents.append(SpikeEvent(time: recordingTime, value: trackingState))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionError = error.localizedDescription
        recording?.interruptions.append(SpikeEvent(time: recordingTime, value: "session failed: \(error.localizedDescription)"))
        pushStats()
    }

    func sessionWasInterrupted(_ session: ARSession) {
        trackingState = "interrupted"
        recording?.interruptions.append(SpikeEvent(time: recordingTime, value: "interrupted"))
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // ARKit may have reset the device while the camera was away.
        recording?.interruptions.append(SpikeEvent(time: recordingTime, value: "interruption ended, re-locking"))
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

    // MARK: - Recording (queue)

    private var recordingTime: Double {
        recording.map { ProcessInfo.processInfo.systemUptime - $0.startUptime } ?? 0
    }

    private func record(_ frame: ARFrame, into recording: SpikeRecording) {
        let accepted = recording.timing.record(frame.timestamp)
        let column = frame.camera.transform.columns.3
        let position = [column.x, column.y, column.z]
        if recording.startPosition == nil { recording.startPosition = position }
        recording.endPosition = position
        guard accepted else { return }

        // Only the pixel buffer outlives this call (the writer retains it
        // until encoded); the ARFrame itself is never kept.
        let image = frame.capturedImage
        let time = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000)
        if recording.writer == nil, recording.writerSetupError == nil {
            let width = CVPixelBufferGetWidth(image)
            let height = CVPixelBufferGetHeight(image)
            recording.imageWidth = width
            recording.imageHeight = height
            recording.pixelFormat = SpikeRunNaming.fourCC(CVPixelBufferGetPixelFormatType(image))
            do {
                recording.writer = try SpikeVideoWriter(url: recording.request.videoURL, width: width, height: height,
                                                        preset: recording.preset, startTime: time)
            } catch {
                recording.writerSetupError = error.localizedDescription
            }
        }
        guard let writer = recording.writer else { return }
        switch writer.append(image, at: time) {
        case .written: recording.framesWritten += 1
        case .droppedBackpressure: recording.framesDroppedBackpressure += 1
        case .failed: recording.appendFailures += 1
        }
    }

    private func readBack() {
        let time = recording != nil ? recordingTime : ProcessInfo.processInfo.systemUptime - sessionStartUptime
        latestReading = readDevice(at: time)
        if let reading = latestReading, case .held = lockPhase {
            latestDeviations = SpikeLockCheck.deviations(of: reading, from: lockTarget)
        } else if let reading = latestReading, lockTarget.lensPosition != nil {
            // Exposure still metering, but the focus lock can be checked.
            latestDeviations = SpikeLockCheck.deviations(of: reading, from: SpikeLockTarget(lensPosition: lockTarget.lensPosition))
        } else {
            latestDeviations = []
        }
        guard let recording else { return }
        if let reading = latestReading {
            recording.readings.append(reading)
            if !latestDeviations.isEmpty {
                recording.deviatingReadings += 1
                if recording.firstDeviation == nil {
                    recording.firstDeviation = String(format: "t=%.1fs ", time) + latestDeviations.joined(separator: ", ")
                }
            }
        }
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal != recording.lastThermal {
            recording.lastThermal = thermal
            recording.thermalEvents.append(SpikeEvent(time: time, value: Self.describe(thermal)))
        }
    }

    private func saveReport(for recording: SpikeRecording, outcome: SpikeVideoWriter.Outcome,
                            lockTarget: SpikeLockTarget, exposureSetting: SpikeExposureSetting?,
                            lockNote: String) -> SpikeStopResult {
        let request = recording.request
        var distance: Float?
        if let start = recording.startPosition, let end = recording.endPosition {
            distance = simd_distance(SIMD3(start[0], start[1], start[2]), SIMD3(end[0], end[1], end[2]))
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: request.videoURL.path)[.size] as? NSNumber)?.int64Value
        var notes = [
            "Exposure \(recording.exposure.rawValue) as selected at record start; changing it mid-take isn't recorded.",
            "\"ARSession is retaining N ARFrames\" warnings only appear in the Xcode console. Starvation shows here as delivered < ~99% of nominal.",
            "Video stabilization: ARKit exposes no AVCaptureConnection, so preferredVideoStabilizationMode can't be set. " + stabilizationNote(),
            "Video HDR: configuration.videoHDRAllowed = false.",
            "Track transform: 90° rotation for portrait. Color tags: BT.709 primaries/transfer/matrix.",
        ]
        if let setupError = recording.writerSetupError { notes.append("Writer setup failed: \(setupError)") }
        let report = SpikeRunReport(
            runName: request.runName, date: request.date, device: request.device,
            preset: recording.preset, exposure: recording.exposure, lighting: request.lighting,
            videoFormat: request.videoFormat, formatList: request.formatList,
            imageWidth: recording.imageWidth, imageHeight: recording.imageHeight, pixelFormat: recording.pixelFormat,
            timing: recording.timing, framesWritten: recording.framesWritten,
            framesDroppedBackpressure: recording.framesDroppedBackpressure, appendFailures: recording.appendFailures,
            exposureSetting: exposureSetting, lockTarget: lockTarget, lockNote: lockNote,
            readings: recording.readings, deviatingReadings: recording.deviatingReadings,
            firstDeviation: recording.firstDeviation,
            trackingEvents: recording.trackingEvents, interruptions: recording.interruptions,
            thermalEvents: recording.thermalEvents,
            startPosition: recording.startPosition, endPosition: recording.endPosition, returnDistanceMeters: distance,
            videoFile: request.videoURL.lastPathComponent, videoBytes: bytes,
            writerStatus: outcome.status, writerError: outcome.error, notes: notes)
        do {
            let url = try SpikeReportStore.save(report, in: request.directory)
            return SpikeStopResult(summary: report.text, reportURL: url, saveError: nil)
        } catch {
            return SpikeStopResult(summary: report.text, reportURL: nil, saveError: error.localizedDescription)
        }
    }

    private func stabilizationNote() -> String {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            return "(no capture device)"
        }
        let modes: [(AVCaptureVideoStabilizationMode, String)] = [
            (.standard, "standard"), (.cinematic, "cinematic"), (.cinematicExtended, "cinematicExtended"),
        ]
        let supported = modes.filter { device.activeFormat.isVideoStabilizationModeSupported($0.0) }.map(\.1)
        return "Active format supports: " + (supported.isEmpty ? "none" : supported.joined(separator: ", "))
            + ". ARKit's capturedImage is believed unstabilized; check the video for wobble."
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
        if let recording {
            stats.isRecording = true
            stats.elapsed = recordingTime
            stats.delivered = recording.timing.delivered
            stats.nominal = recording.timing.nominalFrames
            stats.written = recording.framesWritten
            stats.droppedBackpressure = recording.framesDroppedBackpressure
            stats.appendFailures = recording.appendFailures
            stats.nonMonotonic = recording.timing.nonMonotonic
            stats.maxGap = recording.timing.maxGap
            stats.longGaps = recording.timing.longGaps
            stats.deviatingReadings = recording.deviatingReadings
            stats.writerError = recording.writerSetupError ?? recording.writer?.errorDescription
            if let start = recording.startPosition, let end = recording.endPosition {
                stats.distanceFromStart = simd_distance(SIMD3(start[0], start[1], start[2]), SIMD3(end[0], end[1], end[2]))
            }
        }
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

    var isRecording = false
    var elapsed: Double = 0
    var delivered = 0
    var nominal = 0
    var written = 0
    var droppedBackpressure = 0
    var appendFailures = 0
    var nonMonotonic = 0
    var maxGap: Double = 0
    var longGaps = 0
    var deviatingReadings = 0
    var writerError: String?
    var distanceFromStart: Float?
    var image = "—"
    var thermal = "—"
}

/// What the model hands the engine at record start.
nonisolated struct SpikeRecordingRequest: Sendable {
    var runName: String
    var directory: URL
    var date: Date
    var device: String
    var lighting: SpikeLighting
    var videoFormat: String
    var formatList: String

    var videoURL: URL { directory.appendingPathComponent(runName + ".mov") }
}

nonisolated struct SpikeStopResult: Sendable {
    var summary: String
    var reportURL: URL?
    var saveError: String?
}

/// One take's mutable state. Confined to the engine's queue, like the
/// engine itself; `@unchecked Sendable` only so the writer's completion can
/// carry it back onto that queue.
nonisolated final class SpikeRecording: @unchecked Sendable {
    let request: SpikeRecordingRequest
    let preset: SpikePreset
    let exposure: SpikeExposureMode
    let startUptime: Double

    var writer: SpikeVideoWriter?
    var writerSetupError: String?
    var timing: SpikeFrameTiming
    var framesWritten = 0
    var framesDroppedBackpressure = 0
    var appendFailures = 0

    var imageWidth: Int?
    var imageHeight: Int?
    var pixelFormat: String?

    var readings: [SpikeDeviceReading] = []
    var deviatingReadings = 0
    var firstDeviation: String?
    var trackingEvents: [SpikeEvent] = []
    var interruptions: [SpikeEvent] = []
    var thermalEvents: [SpikeEvent] = []
    var lastThermal = ProcessInfo.ThermalState.nominal
    var startPosition: [Float]?
    var endPosition: [Float]?

    init(request: SpikeRecordingRequest, preset: SpikePreset, exposure: SpikeExposureMode, startUptime: Double) {
        self.request = request
        self.preset = preset
        self.exposure = exposure
        self.startUptime = startUptime
        timing = SpikeFrameTiming(framesPerSecond: preset.framesPerSecond)
    }
}
