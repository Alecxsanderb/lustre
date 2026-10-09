//
//  SpikeReport.swift
//  Lustre
//
//  THROWAWAY (Capture commit 0). One run's measurements, written as
//  `<run>.json` and appended in readable form to `spike-report.txt`, both in
//  Documents/CaptureSpike/.
//

import Foundation

nonisolated struct SpikeEvent: Equatable, Codable, Sendable {
    /// Seconds since recording was requested.
    var time: Double
    var value: String
}

nonisolated struct SpikeRunReport: Codable, Sendable {
    var runName: String
    var date: Date
    var device: String
    var preset: SpikePreset
    var exposure: SpikeExposureMode
    var lighting: SpikeLighting
    var videoFormat: String
    var formatList: String

    var imageWidth: Int?
    var imageHeight: Int?
    var pixelFormat: String?

    var timing: SpikeFrameTiming
    var framesWritten: Int
    var framesDroppedBackpressure: Int
    var appendFailures: Int

    var exposureSetting: SpikeExposureSetting?
    var lockTarget: SpikeLockTarget
    var lockNote: String
    var readings: [SpikeDeviceReading]
    var deviatingReadings: Int
    var firstDeviation: String?

    var trackingEvents: [SpikeEvent]
    var interruptions: [SpikeEvent]
    var thermalEvents: [SpikeEvent]

    var startPosition: [Float]?
    var endPosition: [Float]?
    var returnDistanceMeters: Float?

    var videoFile: String
    var videoBytes: Int64?
    var writerStatus: String
    var writerError: String?
    var notes: [String]

    // MARK: Derived

    var deliveredFraction: Double {
        timing.nominalFrames > 0 ? Double(timing.delivered) / Double(timing.nominalFrames) : 0
    }

    /// Frames missing from the file relative to a perfect stream: ARKit
    /// starvation, backpressure, and rejected timestamps together.
    var lossPercentVersusNominal: Double {
        timing.nominalFrames > 0 ? 100 * (1 - Double(framesWritten) / Double(timing.nominalFrames)) : 0
    }

    var backpressureDropPercent: Double {
        timing.delivered > 0 ? 100 * Double(framesDroppedBackpressure) / Double(timing.delivered) : 0
    }

    // MARK: Text

    var text: String {
        func f(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
        func shutter(_ seconds: Double) -> String { seconds > 0 ? "1/\(Int((1 / seconds).rounded())) s" : "?" }

        var lines: [String] = []
        lines.append("==== \(runName) ====")
        lines.append("Date: \(ISO8601DateFormatter().string(from: date))   Device: \(device)")
        lines.append("Preset: \(preset.rawValue)   Exposure: \(exposure.rawValue)   Lighting: \(lighting.rawValue)")
        lines.append("Video format: \(videoFormat)")
        if let imageWidth, let imageHeight {
            lines.append("capturedImage: \(imageWidth)×\(imageHeight) \(pixelFormat ?? "?")")
        }
        lines.append("")
        lines.append("-- Frames --")
        lines.append("Duration: \(f(timing.elapsed)) s")
        lines.append("Delivered: \(timing.delivered) of nominal \(timing.nominalFrames) (\(f(100 * deliveredFraction))%)  <- below ~99% suggests ARKit frame starvation")
        lines.append("Written: \(framesWritten)   Loss vs nominal: \(f(lossPercentVersusNominal, 2))%")
        lines.append("Dropped (backpressure): \(framesDroppedBackpressure) (\(f(backpressureDropPercent, 2))% of delivered)   Append failures: \(appendFailures)")
        lines.append("Non-monotonic timestamps: \(timing.nonMonotonic)")
        lines.append("Max gap: \(f(timing.maxGap * 1000)) ms   Gaps > 1.5× nominal (\(f(timing.nominalInterval * 1500)) ms): \(timing.longGaps)")
        lines.append("")
        lines.append("-- Exposure --")
        lines.append("Lock: \(lockNote)")
        if let exposureSetting {
            lines.append("Set: \(shutter(exposureSetting.duration)), ISO \(f(Double(exposureSetting.iso), 0))"
                + (exposureSetting.isUnderexposed ? "  UNDEREXPOSED (ISO clamped at max)" : "")
                + (exposureSetting.isOverexposed ? "  OVEREXPOSED (ISO clamped at min)" : ""))
        }
        if let gains = lockTarget.whiteBalanceGains {
            lines.append("WB set: " + gains.map { f(Double($0), 3) }.joined(separator: " / "))
        }
        if let lens = lockTarget.lensPosition { lines.append("Focus locked at lens \(f(Double(lens), 3))") }
        lines.append("Read-backs: \(readings.count), deviating from lock: \(deviatingReadings)"
            + (firstDeviation.map { "  first: \($0)" } ?? ""))
        let durations = readings.map(\.duration).filter { $0 > 0 }
        let isos = readings.map { Double($0.iso) }
        if let minD = durations.min(), let maxD = durations.max(), let minI = isos.min(), let maxI = isos.max() {
            lines.append("Shutter range read back: \(shutter(maxD)) .. \(shutter(minD))   ISO range: \(f(minI, 0)) .. \(f(maxI, 0))")
        }
        for reading in readings.prefix(3) + (readings.count > 3 ? [readings[readings.count - 1]] : []) {
            lines.append("  t=\(f(reading.time))s \(shutter(reading.duration)) ISO \(f(Double(reading.iso), 0)) lens \(f(Double(reading.lensPosition), 3)) "
                + "WB \(reading.whiteBalanceGains.map { f(Double($0), 2) }.joined(separator: "/")) "
                + "modes \(reading.exposureMode)/\(reading.whiteBalanceMode)/\(reading.focusMode)")
        }
        lines.append("")
        lines.append("-- Tracking --")
        lines.append(trackingEvents.isEmpty ? "(no events)"
            : trackingEvents.map { "t=\(f($0.time))s \($0.value)" }.joined(separator: "\n"))
        if !interruptions.isEmpty {
            lines.append("Interruptions: " + interruptions.map { "t=\(f($0.time))s \($0.value)" }.joined(separator: ", "))
        }
        if let returnDistanceMeters, let startPosition, let endPosition {
            func p(_ v: [Float]) -> String { "(" + v.map { f(Double($0), 3) }.joined(separator: ", ") + ")" }
            lines.append("Position start \(p(startPosition)) stop \(p(endPosition))  return distance: \(f(Double(returnDistanceMeters), 3)) m")
        }
        lines.append("")
        lines.append("-- Thermal --")
        lines.append(thermalEvents.map { "t=\(f($0.time))s \($0.value)" }.joined(separator: "\n"))
        lines.append("")
        lines.append("-- Writer --")
        lines.append("File: \(videoFile)  \(videoBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?")")
        lines.append("Status: \(writerStatus)" + (writerError.map { "  error: \($0)" } ?? ""))
        lines.append("")
        lines.append("-- Notes --")
        lines.append(contentsOf: notes.map { "- " + $0 })
        lines.append("")
        lines.append("-- ARKit video formats --")
        lines.append(formatList)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

nonisolated enum SpikeReportStore {
    static let reportFileName = "spike-report.txt"

    /// Writes `<run>.json` and appends the text report. Returns the text
    /// report's URL.
    @discardableResult
    static func save(_ report: SpikeRunReport, in directory: URL) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: directory.appendingPathComponent(report.runName + ".json"), options: .atomic)

        let textURL = directory.appendingPathComponent(reportFileName)
        let data = Data((report.text + "\n").utf8)
        if FileManager.default.fileExists(atPath: textURL.path) {
            let handle = try FileHandle(forWritingTo: textURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: textURL, options: .atomic)
        }
        return textURL
    }
}
