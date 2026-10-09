//
//  SpikeLogic.swift
//  Lustre
//
//  THROWAWAY (Capture commit 0). The ARKit-free parts of the capture spike:
//  preset -> format choice, shutter/ISO compensation, lock drift checks, and
//  frame timing. Plain values so they run in the simulator's unit tests.
//  Delete this folder when the spike's questions are answered; the real
//  versions land in Core/ and Services/ per docs/capture-plan.md.
//

import CoreGraphics
import Foundation

// MARK: - Presets and format choice

/// The three configurations the spike measures.
nonisolated enum SpikePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case hd30 = "HD30"
    case hd60 = "HD60"
    case uhd30 = "4K30"

    var id: String { rawValue }

    var framesPerSecond: Int {
        switch self {
        case .hd30, .uhd30: 30
        case .hd60: 60
        }
    }

    /// Average HEVC bit rate, from the plan's table.
    var bitsPerSecond: Int {
        switch self {
        case .hd30: 25_000_000
        case .hd60: 40_000_000
        case .uhd30: 80_000_000
        }
    }
}

/// An `ARVideoFormat` reduced to what selection needs.
nonisolated struct SpikeFormatCandidate: Equatable, Sendable {
    var width: Int
    var height: Int
    var framesPerSecond: Int
    /// Back-facing `.builtInWideAngleCamera`. Ultra-wide and front formats
    /// are never chosen.
    var isWideBackCamera: Bool
}

nonisolated enum SpikeFormatChoice: Equatable, Sendable {
    /// Index into the candidate list (same order as `supportedVideoFormats`).
    case available(index: Int)
    case unavailable(reason: String)
}

nonisolated enum SpikeFormatSelection {
    /// HD prefers 1920×1440 (4:3, the sensor's native aspect) and falls back
    /// to 1920×1080. 4K is 3840×2160. Wide back camera only, exact fps.
    static func choose(_ preset: SpikePreset, from candidates: [SpikeFormatCandidate]) -> SpikeFormatChoice {
        let fps = preset.framesPerSecond
        let resolutions: [(Int, Int)] = switch preset {
        case .hd30, .hd60: [(1920, 1440), (1920, 1080)]
        case .uhd30: [(3840, 2160)]
        }
        for (width, height) in resolutions {
            if let index = candidates.firstIndex(where: {
                $0.isWideBackCamera && $0.width == width && $0.height == height && $0.framesPerSecond == fps
            }) {
                return .available(index: index)
            }
        }
        let wanted = resolutions.map { "\($0.0)×\($0.1)" }.joined(separator: " or ")
        if candidates.isEmpty {
            return .unavailable(reason: "ARKit lists no video formats")
        }
        return .unavailable(reason: "No wide back-camera \(wanted) format at \(fps) fps")
    }
}

// MARK: - Exposure

nonisolated enum SpikeExposureMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "Auto"
    case shutter250 = "1/250"
    case shutter500 = "1/500"

    var id: String { rawValue }

    /// Fixed shutter in seconds, or nil for ARKit's own auto exposure.
    var targetDuration: Double? {
        switch self {
        case .auto: nil
        case .shutter250: 1.0 / 250
        case .shutter500: 1.0 / 500
        }
    }
}

nonisolated struct SpikeExposureSetting: Equatable, Codable, Sendable {
    var duration: Double
    var iso: Float
    /// ISO hit the format's maximum: the image is darker than auto exposure was.
    var isUnderexposed: Bool
    /// ISO hit the minimum (auto was already faster than the target).
    var isOverexposed: Bool
}

nonisolated enum SpikeExposureMath {
    /// Holds brightness when moving from auto exposure to a fixed shutter:
    /// exposure ∝ ISO × duration, so `iso = currentISO × currentDuration /
    /// targetDuration`, clamped to the active format's ISO range. The
    /// duration is clamped to the format's range too.
    static func compensate(currentISO: Float, currentDuration: Double,
                           targetDuration: Double,
                           isoRange: ClosedRange<Float>,
                           durationRange: ClosedRange<Double>) -> SpikeExposureSetting {
        let duration = min(max(targetDuration, durationRange.lowerBound), durationRange.upperBound)
        let ideal = duration > 0 ? Double(currentISO) * currentDuration / duration : Double(isoRange.upperBound)
        let iso = Float(min(max(ideal, Double(isoRange.lowerBound)), Double(isoRange.upperBound)))
        return SpikeExposureSetting(duration: duration, iso: iso,
                                    isUnderexposed: ideal > Double(isoRange.upperBound),
                                    isOverexposed: ideal < Double(isoRange.lowerBound))
    }
}

// MARK: - Lock read-back

/// What the spike set on the capture device. Nil fields weren't locked.
nonisolated struct SpikeLockTarget: Equatable, Codable, Sendable {
    var duration: Double?
    var iso: Float?
    var whiteBalanceGains: [Float]?
    var lensPosition: Float?
}

/// One 1 Hz read-back of the capture device.
nonisolated struct SpikeDeviceReading: Equatable, Codable, Sendable {
    /// Seconds since recording started (or since the session started, in preview).
    var time: Double
    var duration: Double
    var iso: Float
    var lensPosition: Float
    var whiteBalanceGains: [Float]
    var exposureMode: String
    var whiteBalanceMode: String
    var focusMode: String
}

nonisolated enum SpikeLockCheck {
    static let relativeTolerance = 0.02
    static let lensTolerance: Float = 0.01

    /// Ways the device no longer matches the lock, e.g. ARKit putting auto
    /// exposure back. Empty means the lock held.
    static func deviations(of reading: SpikeDeviceReading, from target: SpikeLockTarget) -> [String] {
        var out: [String] = []
        if let duration = target.duration {
            if reading.exposureMode != "custom" { out.append("exposure mode \(reading.exposureMode)") }
            if !isClose(reading.duration, duration) {
                out.append(String(format: "shutter 1/%.0f (set 1/%.0f)", 1 / reading.duration, 1 / duration))
            }
        }
        if let iso = target.iso, !isClose(Double(reading.iso), Double(iso)) {
            out.append(String(format: "ISO %.0f (set %.0f)", reading.iso, iso))
        }
        if let gains = target.whiteBalanceGains {
            if reading.whiteBalanceMode != "locked" { out.append("white balance mode \(reading.whiteBalanceMode)") }
            if gains.count != reading.whiteBalanceGains.count
                || zip(gains, reading.whiteBalanceGains).contains(where: { !isClose(Double($1), Double($0)) }) {
                out.append("white balance gains changed")
            }
        }
        if let lens = target.lensPosition {
            if reading.focusMode != "locked" { out.append("focus mode \(reading.focusMode)") }
            if abs(reading.lensPosition - lens) > lensTolerance {
                out.append(String(format: "lens %.3f (set %.3f)", reading.lensPosition, lens))
            }
        }
        return out
    }

    private static func isClose(_ value: Double, _ target: Double) -> Bool {
        guard target != 0 else { return value == 0 }
        return abs(value - target) / abs(target) <= relativeTolerance
    }
}

// MARK: - Frame timing

/// Counts delivered frames, rejects non-increasing timestamps, and tracks
/// inter-frame gaps against the nominal interval.
nonisolated struct SpikeFrameTiming: Equatable, Codable, Sendable {
    let framesPerSecond: Int
    private(set) var delivered = 0
    private(set) var nonMonotonic = 0
    private(set) var maxGap: Double = 0
    /// Gaps longer than 1.5× the nominal interval (at least one frame missing).
    private(set) var longGaps = 0
    private(set) var firstTimestamp: Double?
    private(set) var lastTimestamp: Double?

    init(framesPerSecond: Int) {
        self.framesPerSecond = framesPerSecond
    }

    var nominalInterval: Double { 1 / Double(framesPerSecond) }

    /// Records a delivered frame. Returns false if its timestamp doesn't
    /// increase, meaning the caller must not append it to the writer.
    mutating func record(_ timestamp: Double) -> Bool {
        delivered += 1
        guard let last = lastTimestamp else {
            firstTimestamp = timestamp
            lastTimestamp = timestamp
            return true
        }
        guard timestamp > last else {
            nonMonotonic += 1
            return false
        }
        let gap = timestamp - last
        maxGap = max(maxGap, gap)
        if gap > 1.5 * nominalInterval { longGaps += 1 }
        lastTimestamp = timestamp
        return true
    }

    var elapsed: Double {
        guard let first = firstTimestamp, let last = lastTimestamp else { return 0 }
        return last - first
    }

    /// Frames a perfect stream would have delivered between the first and
    /// last timestamps: fps × elapsed, plus the first frame.
    var nominalFrames: Int {
        firstTimestamp == nil ? 0 : Int((elapsed * Double(framesPerSecond)).rounded()) + 1
    }
}

// MARK: - Misc

nonisolated enum SpikeVideoGeometry {
    /// `capturedImage` is in the sensor's landscape-right orientation; a
    /// 90° clockwise rotation displays it portrait.
    static let portraitTrackTransform = CGAffineTransform(rotationAngle: .pi / 2)
}

nonisolated enum SpikeLighting: String, CaseIterable, Identifiable, Codable, Sendable {
    case bright = "Bright"
    case dim = "Dim"
    var id: String { rawValue }
}

nonisolated enum SpikeRunNaming {
    static func runName(date: Date, preset: SpikePreset, exposure: SpikeExposureMode,
                        lighting: SpikeLighting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let shutter = exposure.rawValue.replacingOccurrences(of: "/", with: "_")
        return "spike-\(formatter.string(from: date))-\(preset.rawValue)-\(shutter)-\(lighting.rawValue)"
    }

    /// `kCVPixelFormatType_*` as its four characters, e.g. "420f".
    static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(code)
    }
}
