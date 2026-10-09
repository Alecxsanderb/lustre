//
//  CaptureSpikeView.swift
//  Lustre
//
//  THROWAWAY (Capture commit 0). Measurement screen for ARKit-backed
//  recording, reached from Settings › Spike (temporary). Not the Capture UI.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

struct CaptureSpikeView: View {
    @State private var model = CaptureSpikeModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isSupported, let session = model.sessionForPreview() {
                content(session: session)
            } else {
                ContentUnavailableView("ARKit unavailable",
                                       systemImage: "arkit",
                                       description: Text("World tracking isn't supported here. The capture spike only runs on an iPhone; the simulator never supports ARKit."))
            }
        }
        .navigationTitle("Capture spike")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.refreshReportURL()
            model.appear()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.disappear()
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }

    private func content(session: ARSession) -> some View {
        VStack(spacing: 0) {
            SpikeARPreview(session: session, onAttach: model.previewAttached)
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .clipped()
                .overlay(alignment: .bottom) { recordButton.padding(12) }
                .overlay(alignment: .topLeading) {
                    if model.isRecording {
                        Text(String(format: "REC %.0f s", model.stats.elapsed))
                            .font(.caption.monospacedDigit().bold())
                            .padding(6)
                            .background(.red, in: .capsule)
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }
            List {
                if let error = model.lastError {
                    Text(error).foregroundStyle(.red)
                }
                setupSection
                    .disabled(model.isRecording || model.isFinishing)
                exposureSection
                    .disabled(model.isRecording || model.isFinishing)
                if model.isRecording { recordingSection }
                liveSection
                reportSection
                formatsSection
            }
        }
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            Label(model.isFinishing ? "Saving…" : model.isRecording ? "Stop" : "Record",
                  systemImage: model.isRecording ? "stop.fill" : "record.circle")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(model.isRecording ? .red : .accentColor)
        .disabled(model.isFinishing)
    }

    private var setupSection: some View {
        Section("Preset and lighting") {
            Picker("Lighting", selection: $model.lighting) {
                ForEach(SpikeLighting.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(SpikePreset.allCases) { preset in
                let choice = model.availability[preset] ?? .unavailable(reason: "Unknown")
                Button {
                    model.preset = preset
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.rawValue)
                            switch choice {
                            case .available(let index):
                                Text(CaptureSpikeModel.describe(model.formats[index]))
                                    .font(.caption).foregroundStyle(.secondary)
                            case .unavailable(let reason):
                                Text(reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if model.preset == preset { Image(systemName: "checkmark") }
                    }
                }
                .disabled(!choice.isAvailable)
            }
        }
    }

    private var exposureSection: some View {
        Section {
            Picker("Exposure", selection: $model.exposure) {
                ForEach(SpikeExposureMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            row("Lock", model.stats.lockNote)
            if !model.stats.deviations.isEmpty {
                Text("Lock not holding: " + model.stats.deviations.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Exposure")
        } footer: {
            Text("Fixed shutters meter on auto for 30 frames, then lock shutter, ISO (raised to keep brightness) and white balance. Focus locks when recording starts.")
        }
    }

    private var recordingSection: some View {
        let stats = model.stats
        return Section("Recording") {
            row("Delivered / nominal", "\(stats.delivered) / \(stats.nominal)"
                + (stats.nominal > 0 ? String(format: " (%.1f%%)", 100 * Double(stats.delivered) / Double(stats.nominal)) : ""))
            row("Written", "\(stats.written)")
            row("Dropped (backpressure)", "\(stats.droppedBackpressure)")
            if stats.appendFailures > 0 { row("Append failures", "\(stats.appendFailures)") }
            row("Non-monotonic", "\(stats.nonMonotonic)")
            row("Max gap / long gaps", String(format: "%.1f ms / %d", stats.maxGap * 1000, stats.longGaps))
            row("Deviating read-backs", "\(stats.deviatingReadings)")
            if let distance = stats.distanceFromStart {
                row("Distance from start", String(format: "%.2f m", distance))
            }
            if let error = stats.writerError { row("Writer error", error) }
        }
    }

    private var reportSection: some View {
        Section {
            if let url = model.reportURL {
                ShareLink(item: url) {
                    Label("Share spike-report.txt", systemImage: "square.and.arrow.up")
                }
            } else {
                Text("No report yet. Record and stop a take.").foregroundStyle(.secondary)
            }
            if let summary = model.lastRunSummary {
                DisclosureGroup("Last run") {
                    Text(summary)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Report")
        } footer: {
            Text("Videos, per-run JSON and the report are in Files › On My iPhone › Lustre › CaptureSpike.")
        }
    }

    private var liveSection: some View {
        Section("Live") {
            row("Tracking", model.stats.trackingState)
            if let error = model.stats.sessionError { row("Session error", error) }
            row("Image", model.stats.image)
            row("Thermal", model.stats.thermal)
            if let reading = model.stats.reading {
                row("Shutter / ISO", String(format: "1/%.0f s, ISO %.0f", 1 / reading.duration, reading.iso))
                row("Lens", String(format: "%.3f", reading.lensPosition))
                row("WB gains", reading.whiteBalanceGains.map { String(format: "%.2f", $0) }.joined(separator: " / "))
                row("Modes (exp/WB/focus)", "\(reading.exposureMode) / \(reading.whiteBalanceMode) / \(reading.focusMode)")
            }
        }
    }

    private var formatsSection: some View {
        Section("ARKit video formats") {
            Text(model.formatListText)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
    }
}

extension SpikeFormatChoice {
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// RealityKit `ARView` showing the spike's own session. It never configures
/// or runs the session itself.
private struct SpikeARPreview: UIViewRepresentable {
    let session: ARSession
    let onAttach: () -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        view.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disablePersonOcclusion,
                              .disableGroundingShadows, .disableAREnvironmentLighting,
                              .disableHDR, .disableCameraGrain, .disableFaceMesh]
        onAttach()
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
