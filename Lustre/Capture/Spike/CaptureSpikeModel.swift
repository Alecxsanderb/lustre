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
    var exposure: SpikeExposureMode = .auto {
        didSet { if exposure != oldValue { engine?.setExposure(exposure) } }
    }
    var lighting: SpikeLighting = .bright

    private(set) var stats = SpikeLiveStats()

    private(set) var isRecording = false
    /// Between Stop and the report being saved.
    private(set) var isFinishing = false
    private(set) var lastRunSummary: String?
    private(set) var lastError: String?
    private(set) var reportURL: URL?

    /// Documents/CaptureSpike: visible in Files, and deliberately not
    /// Documents/Splats, which the library treats as splats.
    static var directory: URL {
        URL.documentsDirectory.appendingPathComponent("CaptureSpike", isDirectory: true)
    }

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

    // MARK: - Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard let engine, isSessionRunning, !isFinishing,
              case .available(let index) = availability[preset] else { return }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        } catch {
            lastError = "Couldn't create CaptureSpike folder: \(error.localizedDescription)"
            return
        }
        let date = Date()
        let request = SpikeRecordingRequest(
            runName: SpikeRunNaming.runName(date: date, preset: preset, exposure: exposure, lighting: lighting),
            directory: Self.directory, date: date, device: Self.deviceDescription, lighting: lighting,
            videoFormat: Self.describe(formats[index]), formatList: formatListText)
        engine.startRecording(request)
        isRecording = true
        lastError = nil
    }

    /// - Parameter completion: runs once the file and report are saved.
    private func stopRecording(completion: (() -> Void)? = nil) {
        guard isRecording, let engine else {
            completion?()
            return
        }
        isRecording = false
        isFinishing = true
        engine.stopRecording { [weak self] result in
            if let self {
                self.isFinishing = false
                if let result {
                    self.lastRunSummary = result.summary
                    self.reportURL = result.reportURL ?? self.reportURL
                    self.lastError = result.saveError.map { "Report not saved: \($0)" }
                }
            }
            completion?()
        }
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

    func refreshReportURL() {
        let url = Self.directory.appendingPathComponent(SpikeReportStore.reportFileName)
        reportURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
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

    /// Leaving the screen or the app: finalize any take under a background
    /// task so the writer can finish, then stop the camera.
    private func suspend() {
        if isRecording {
            let application = UIApplication.shared
            var task = UIBackgroundTaskIdentifier.invalid
            task = application.beginBackgroundTask(withName: "Finish capture spike recording") {
                application.endBackgroundTask(task)
                task = .invalid
            }
            stopRecording {
                if task != .invalid { application.endBackgroundTask(task) }
                task = .invalid
            }
        }
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
        engine.run(configuration, preset: preset, exposure: exposure, resetTracking: resetTracking)
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

    private static var deviceDescription: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return "\(machine), iOS \(UIDevice.current.systemVersion)"
    }

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
