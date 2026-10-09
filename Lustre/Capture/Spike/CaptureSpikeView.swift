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
            List {
                presetSection
                exposureSection
                liveSection
                formatsSection
            }
        }
    }

    private var presetSection: some View {
        Section("Preset") {
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
