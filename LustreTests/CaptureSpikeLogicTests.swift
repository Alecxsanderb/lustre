//
//  CaptureSpikeLogicTests.swift
//  LustreTests
//
//  The ARKit-free parts of the throwaway capture spike: format choice,
//  shutter/ISO compensation, lock drift checks, and frame timing. Delete
//  with Lustre/Capture/Spike/.
//

import Foundation
import Testing
@testable import Lustre

struct SpikeFormatSelectionTests {

    private func wide(_ w: Int, _ h: Int, _ fps: Int) -> SpikeFormatCandidate {
        SpikeFormatCandidate(width: w, height: h, framesPerSecond: fps, isWideBackCamera: true)
    }

    private func ultraWide(_ w: Int, _ h: Int, _ fps: Int) -> SpikeFormatCandidate {
        SpikeFormatCandidate(width: w, height: h, framesPerSecond: fps, isWideBackCamera: false)
    }

    @Test func hdPrefers1440Over1080() {
        let list = [wide(1920, 1080, 30), wide(1920, 1440, 30), wide(3840, 2160, 30)]
        #expect(SpikeFormatSelection.choose(.hd30, from: list) == .available(index: 1))
    }

    @Test func hdFallsBackTo1080() {
        let list = [wide(1920, 1080, 60), wide(3840, 2160, 30)]
        #expect(SpikeFormatSelection.choose(.hd60, from: list) == .available(index: 0))
    }

    @Test func frameRateMustMatch() {
        let list = [wide(1920, 1440, 60)]
        #expect(!SpikeFormatSelection.choose(.hd30, from: list).isAvailable)
        #expect(SpikeFormatSelection.choose(.hd60, from: list) == .available(index: 0))
    }

    @Test func ultraWideIsNeverChosen() {
        let list = [ultraWide(1920, 1440, 30), ultraWide(3840, 2160, 30), wide(1920, 1080, 30)]
        #expect(SpikeFormatSelection.choose(.hd30, from: list) == .available(index: 2))
        #expect(!SpikeFormatSelection.choose(.uhd30, from: list).isAvailable)
    }

    @Test func fourKNeedsWide3840At30() {
        let list = [wide(3840, 2160, 60), wide(1920, 1440, 30), wide(3840, 2160, 30)]
        #expect(SpikeFormatSelection.choose(.uhd30, from: list) == .available(index: 2))
    }

    @Test func unavailableExplainsWhy() {
        guard case .unavailable(let reason) = SpikeFormatSelection.choose(.hd60, from: [wide(1920, 1440, 30)]) else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("60 fps"))
        #expect(reason.contains("1920×1440"))
    }

    @Test func emptyListIsUnavailable() {
        for preset in SpikePreset.allCases {
            #expect(!SpikeFormatSelection.choose(preset, from: []).isAvailable)
        }
    }
}

struct SpikeExposureMathTests {
    private let isoRange: ClosedRange<Float> = 50...2000
    private let durationRange: ClosedRange<Double> = (1.0 / 10_000)...(1.0 / 3)

    @Test func scalesISOToKeepBrightness() {
        // Auto at 1/60 s ISO 100 -> 1/250 s needs ISO 100 × 250/60.
        let setting = SpikeExposureMath.compensate(currentISO: 100, currentDuration: 1.0 / 60,
                                                   targetDuration: 1.0 / 250,
                                                   isoRange: isoRange, durationRange: durationRange)
        #expect(setting.duration == 1.0 / 250)
        #expect(abs(setting.iso - 416.667) < 0.01)
        #expect(!setting.isUnderexposed)
        #expect(!setting.isOverexposed)
    }

    @Test func clampsAtMaxISOAndFlagsUnderexposed() {
        // Dim room: 1/30 s ISO 1000 -> 1/500 s would need ISO 16 667.
        let setting = SpikeExposureMath.compensate(currentISO: 1000, currentDuration: 1.0 / 30,
                                                   targetDuration: 1.0 / 500,
                                                   isoRange: isoRange, durationRange: durationRange)
        #expect(setting.iso == 2000)
        #expect(setting.isUnderexposed)
        #expect(!setting.isOverexposed)
    }

    @Test func clampsAtMinISOAndFlagsOverexposed() {
        // Daylight: auto already at 1/2000 s ISO 50, slowing to 1/250.
        let setting = SpikeExposureMath.compensate(currentISO: 50, currentDuration: 1.0 / 2000,
                                                   targetDuration: 1.0 / 250,
                                                   isoRange: isoRange, durationRange: durationRange)
        #expect(setting.iso == 50)
        #expect(setting.isOverexposed)
        #expect(!setting.isUnderexposed)
    }

    @Test func exactMaxIsNotUnderexposed() {
        let setting = SpikeExposureMath.compensate(currentISO: 500, currentDuration: 1.0 / 125,
                                                   targetDuration: 1.0 / 500,
                                                   isoRange: isoRange, durationRange: durationRange)
        #expect(setting.iso == 2000)
        #expect(!setting.isUnderexposed)
    }

    @Test func clampsDurationToFormat() {
        let setting = SpikeExposureMath.compensate(currentISO: 100, currentDuration: 1.0 / 60,
                                                   targetDuration: 1.0 / 250,
                                                   isoRange: isoRange,
                                                   durationRange: (1.0 / 10_000)...(1.0 / 1000))
        #expect(setting.duration == 1.0 / 1000)
        // Brightness math uses the clamped duration.
        #expect(abs(setting.iso - Float(100.0 * 1000 / 60)) < 0.01)
    }

    @Test func fixedModesAreNeverSlowerThan250() {
        for mode in SpikeExposureMode.allCases {
            if let duration = mode.targetDuration { #expect(duration <= 1.0 / 250) }
        }
        #expect(SpikeExposureMode.auto.targetDuration == nil)
    }
}

struct SpikeLockCheckTests {
    private let target = SpikeLockTarget(duration: 1.0 / 250, iso: 400,
                                         whiteBalanceGains: [2.0, 1.0, 1.8], lensPosition: 0.6)

    private func reading(duration: Double = 1.0 / 250, iso: Float = 400, lens: Float = 0.6,
                         gains: [Float] = [2.0, 1.0, 1.8], exposureMode: String = "custom",
                         whiteBalanceMode: String = "locked", focusMode: String = "locked") -> SpikeDeviceReading {
        SpikeDeviceReading(time: 1, duration: duration, iso: iso, lensPosition: lens, whiteBalanceGains: gains,
                           exposureMode: exposureMode, whiteBalanceMode: whiteBalanceMode, focusMode: focusMode)
    }

    @Test func heldLockHasNoDeviations() {
        #expect(SpikeLockCheck.deviations(of: reading(), from: target).isEmpty)
        // Within the 2% tolerance (sensor rounding).
        #expect(SpikeLockCheck.deviations(of: reading(duration: 1.0 / 252, iso: 404), from: target).isEmpty)
    }

    @Test func detectsARKitRestoringAutoExposure() {
        let found = SpikeLockCheck.deviations(of: reading(duration: 1.0 / 60, iso: 100, exposureMode: "continuous"),
                                              from: target)
        #expect(found.contains("exposure mode continuous"))
        #expect(found.contains { $0.hasPrefix("shutter") })
        #expect(found.contains { $0.hasPrefix("ISO") })
    }

    @Test func detectsWhiteBalanceAndFocusDrift() {
        let found = SpikeLockCheck.deviations(of: reading(lens: 0.7, gains: [2.2, 1.0, 1.8],
                                                          focusMode: "continuous"), from: target)
        #expect(found.contains("white balance gains changed"))
        #expect(found.contains("focus mode continuous"))
        #expect(found.contains { $0.hasPrefix("lens") })
    }

    @Test func unlockedFieldsAreIgnored() {
        let autoTarget = SpikeLockTarget(lensPosition: 0.6)
        let auto = reading(duration: 1.0 / 30, iso: 900, gains: [1.5, 1, 2],
                           exposureMode: "continuous", whiteBalanceMode: "continuous")
        #expect(SpikeLockCheck.deviations(of: auto, from: autoTarget).isEmpty)
    }
}

struct SpikeFrameTimingTests {

    @Test func perfectStreamMatchesNominal() {
        var timing = SpikeFrameTiming(framesPerSecond: 30)
        for i in 0..<300 {
            let accepted = timing.record(100 + Double(i) / 30)
            #expect(accepted)
        }
        #expect(timing.delivered == 300)
        #expect(timing.nominalFrames == 300)
        #expect(timing.longGaps == 0)
        #expect(timing.nonMonotonic == 0)
        #expect(abs(timing.maxGap - 1.0 / 30) < 1e-9)
    }

    @Test func missingFramesShowAsGapsAndShortfall() {
        var timing = SpikeFrameTiming(framesPerSecond: 60)
        // 0..59 with frames 10, 11, 12 and 40 missing.
        for i in 0..<60 where ![10, 11, 12, 40].contains(i) {
            _ = timing.record(Double(i) / 60)
        }
        #expect(timing.delivered == 56)
        #expect(timing.nominalFrames == 60)
        #expect(timing.longGaps == 2)
        #expect(abs(timing.maxGap - 4.0 / 60) < 1e-9)
    }

    @Test func jitterUnderOneAndAHalfIntervalsIsNotAGap() {
        var timing = SpikeFrameTiming(framesPerSecond: 30)
        _ = timing.record(0)
        _ = timing.record(1.4 / 30)
        #expect(timing.longGaps == 0)
        _ = timing.record(1.4 / 30 + 1.6 / 30)
        #expect(timing.longGaps == 1)
    }

    @Test func nonIncreasingTimestampsAreRejectedAndCounted() {
        var timing = SpikeFrameTiming(framesPerSecond: 30)
        let accepted = [
            timing.record(1.0),
            timing.record(1.0 + 1.0 / 30),
            timing.record(1.0 + 1.0 / 30),  // repeat
            timing.record(1.0),             // backwards
            timing.record(1.0 + 2.0 / 30),
        ]
        #expect(accepted == [true, true, false, false, true])
        #expect(timing.delivered == 5)
        #expect(timing.nonMonotonic == 2)
        #expect(timing.lastTimestamp == 1.0 + 2.0 / 30)
        // Rejected frames don't count as gaps.
        #expect(timing.longGaps == 0)
    }

    @Test func emptyTimingHasNoNominalFrames() {
        let timing = SpikeFrameTiming(framesPerSecond: 30)
        #expect(timing.nominalFrames == 0)
        #expect(timing.elapsed == 0)
    }
}

struct SpikeNamingTests {
    @Test func fourCCOfARKitFormat() {
        // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        #expect(SpikeRunNaming.fourCC(0x3432_3066) == "420f")
    }

    @Test func runNameIsFileSafe() {
        let name = SpikeRunNaming.runName(date: Date(timeIntervalSince1970: 0), preset: .uhd30,
                                          exposure: .shutter500, lighting: .dim)
        #expect(!name.contains("/"))
        #expect(name.hasSuffix("-4K30-1_500-Dim"))
    }
}
