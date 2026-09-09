//
//  ControlMenu.swift
//  Lustre
//
//  Every viewer control, in one panel that collapses to a single button.
//
//  Deliberately not a `.popover`: on iPhone that adapts into a sheet, which
//  would cover the live Metal view the controls are meant to adjust.
//

import SwiftUI
import simd

struct ControlMenu: View {
    @Bindable var sceneState: SplatSceneState
    @Bindable var uiState: ViewerUIState

    var statusMessage: String?
    var isPassthroughAvailable: Bool
    var onRecenter: () -> Void
    var onBackgroundChange: (ViewerUIState.Background) -> Void

    /// One nudge step, in meters. Small enough to fine-tune, large enough that
    /// repeated taps get somewhere.
    private static let nudgeStep: Float = 0.05

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if uiState.isMenuExpanded {
                expandedPanel
                    .transition(.scale(scale: 0.9, anchor: .bottomTrailing)
                        .combined(with: .opacity))
            }
            collapsedPill
        }
        .animation(.snappy(duration: 0.22), value: uiState.isMenuExpanded)
        .animation(.snappy(duration: 0.22), value: uiState.expandedSection)
        .padding(.horizontal, 16)
    }

    // MARK: - Collapsed

    /// Status stays visible when the panel is closed — otherwise minimizing the
    /// menu also hides "loading" and tracking warnings.
    private var collapsedPill: some View {
        HStack(spacing: 10) {
            statusSummary
            Spacer(minLength: 8)
            if uiState.areGesturesEnabled {
                Image(systemName: "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Touch controls on")
            }
            Button {
                uiState.isMenuExpanded.toggle()
            } label: {
                Image(systemName: uiState.isMenuExpanded ? "xmark" : "slider.horizontal.3")
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Circle())
            .accessibilityLabel(uiState.isMenuExpanded ? "Hide controls" : "Show controls")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var statusSummary: some View {
        switch sceneState.loadState {
        case .empty:
            Text("No splat loaded").font(.footnote).foregroundStyle(.secondary)
        case .loading(let name):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading \(name)…").font(.footnote).lineLimit(1)
            }
        case .loaded(let name, let splatCount):
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.footnote.weight(.medium)).lineLimit(1)
                if let statusMessage {
                    Text(statusMessage).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text("^[\(splatCount) splat](inflect: true) · \(SplatScale.formatted(sceneState.scale))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    // MARK: - Expanded

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ViewerUIState.Section.allCases) { section in
                sectionDisclosure(section)
                if section != ViewerUIState.Section.allCases.last {
                    Divider().opacity(0.4)
                }
            }
            Divider().opacity(0.4)
            gestureToggle
        }
        .padding(14)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func sectionDisclosure(_ section: ViewerUIState.Section) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                uiState.toggle(section)
            } label: {
                HStack {
                    Label(section.title, systemImage: section.systemImage)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(uiState.expandedSection == section ? 0 : -90))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if uiState.expandedSection == section {
                switch section {
                case .placement: scaleControls
                case .orientation: orientationControls
                case .position: positionControls
                case .display: displayControls
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Scale

    private var scaleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(SplatScale.formatted(sceneState.scale))
                    .font(.footnote.monospacedDigit().weight(.medium))
                Spacer()
                Text("pinch to fine-tune")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            // Logarithmic: the useful range spans six decades, and a linear
            // slider would put everything below 1× in the leftmost pixel.
            Slider(value: Binding(
                get: { SplatScale.sliderPosition(for: sceneState.scale) },
                set: { sceneState.scale = SplatScale.scale(forSliderPosition: $0) }
            ), in: 0...1)
            .accessibilityLabel("Splat scale")
            .accessibilityValue(SplatScale.formatted(sceneState.scale))

            HStack(spacing: 8) {
                Button("Fit") { sceneState.fitToView() }
                Button("Life size") { sceneState.useAuthoredScale() }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
    }

    // MARK: - Orientation

    private var orientationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            angleSlider("Yaw", value: $sceneState.yaw)

            Toggle("Pitch and roll", isOn: $uiState.showsAdvancedRotation)
                .font(.footnote)
                .toggleStyle(.switch)

            if uiState.showsAdvancedRotation {
                angleSlider("Pitch", value: $sceneState.pitch)
                angleSlider("Roll", value: $sceneState.roll)
            }
        }
    }

    private func angleSlider(_ title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue * 180 / .pi))°")
                    .font(.caption.monospacedDigit())
            }
            Slider(value: value, in: -Float.pi...Float.pi)
                .accessibilityLabel(title)
        }
    }

    // MARK: - Position

    private var positionControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Two-finger drag to move, or nudge:")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                nudgeButton("arrow.left", axis: SIMD3(-1, 0, 0))
                nudgeButton("arrow.right", axis: SIMD3(1, 0, 0))
                nudgeButton("arrow.up", axis: SIMD3(0, 1, 0))
                nudgeButton("arrow.down", axis: SIMD3(0, -1, 0))
                nudgeButton("arrow.up.forward", axis: SIMD3(0, 0, -1))
                nudgeButton("arrow.down.backward", axis: SIMD3(0, 0, 1))
            }
            .buttonStyle(.bordered)

            Text(String(format: "x %.2f  y %.2f  z %.2f m",
                        sceneState.translation.x,
                        sceneState.translation.y,
                        sceneState.translation.z))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func nudgeButton(_ systemImage: String, axis: SIMD3<Float>) -> some View {
        Button {
            sceneState.translation += axis * Self.nudgeStep
        } label: {
            Image(systemName: systemImage).font(.footnote)
        }
        .accessibilityLabel("Nudge \(systemImage)")
    }

    // MARK: - Display

    private var displayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Background", selection: Binding(
                get: { uiState.background },
                set: { onBackgroundChange($0) }
            )) {
                ForEach(ViewerUIState.Background.allCases) { background in
                    Label(background.title, systemImage: background.systemImage)
                        .tag(background)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!isPassthroughAvailable)

            if !isPassthroughAvailable {
                Text("Camera background needs a device with AR support.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("Flip up axis", isOn: $sceneState.appliesUpCalibration)
                .font(.footnote)

            HStack(spacing: 8) {
                Button { onRecenter() } label: { Label("Recenter", systemImage: "scope") }
                Button { sceneState.resetPlacement() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
    }

    private var gestureToggle: some View {
        Toggle(isOn: $uiState.areGesturesEnabled) {
            Label("Touch controls", systemImage: "hand.draw")
                .font(.subheadline.weight(.medium))
        }
        .padding(.top, 2)
    }
}
