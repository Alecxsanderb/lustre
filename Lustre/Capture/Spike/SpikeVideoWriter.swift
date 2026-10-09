//
//  SpikeVideoWriter.swift
//  Lustre
//
//  THROWAWAY (Capture commit 0). HEVC fragmented .mov straight from
//  `ARFrame.capturedImage`. No audio.
//
//  Confined to the engine's queue like everything else that touches frames:
//  created, appended to, and finished there. `@unchecked Sendable` only so
//  `finishWriting`'s completion can hop back onto that queue.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

nonisolated final class SpikeVideoWriter: @unchecked Sendable {

    enum AppendResult {
        case written
        /// `isReadyForMoreMediaData` was false: the encoder is behind.
        case droppedBackpressure
        case failed
    }

    struct Outcome: Sendable {
        var status: String
        var error: String?
    }

    enum SetupError: LocalizedError {
        case cannotAddInput
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "AVAssetWriter can't add the HEVC input"
            case .startFailed(let reason): "startWriting failed: \(reason)"
            }
        }
    }

    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private var lastTime: CMTime?

    /// Starts the writer's session at `startTime`, the first frame's time.
    init(url: URL, width: Int, height: Int, preset: SpikePreset, startTime: CMTime) throws {
        self.url = url
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(preset.framesPerSecond))
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // Fragments keep everything up to the last second playable if the
        // app dies mid-take.
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitsPerSecond,
                AVVideoExpectedSourceFrameRateKey: preset.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: preset.framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = SpikeVideoGeometry.portraitTrackTransform
        // No source attributes: ARKit's buffers are appended as they are.
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        guard writer.canAdd(input) else { throw SetupError.cannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw SetupError.startFailed(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: startTime)
    }

    func append(_ buffer: CVPixelBuffer, at time: CMTime) -> AppendResult {
        guard writer.status == .writing else { return .failed }
        guard input.isReadyForMoreMediaData else { return .droppedBackpressure }
        guard adaptor.append(buffer, withPresentationTime: time) else { return .failed }
        lastTime = time
        return .written
    }

    var errorDescription: String? { writer.error?.localizedDescription }

    /// `completion` runs on an arbitrary queue.
    func finish(completion: @escaping @Sendable (Outcome) -> Void) {
        guard writer.status == .writing else {
            completion(Outcome(status: Self.describe(writer.status), error: writer.error?.localizedDescription))
            return
        }
        if let lastTime { writer.endSession(atSourceTime: CMTimeAdd(lastTime, frameDuration)) }
        input.markAsFinished()
        writer.finishWriting {
            completion(Outcome(status: Self.describe(self.writer.status),
                               error: self.writer.error?.localizedDescription))
        }
    }

    static func describe(_ status: AVAssetWriter.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .writing: "writing"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        @unknown default: "unknown"
        }
    }
}
