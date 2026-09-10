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
    var isPlacementAvailable: Bool
    var isOcclusionAvailable: Bool
    /// Minor and major tick intervals, named — the gizmo draws no text, so
    /// this is where the notches get their units.
    var rulerDescription: (minor: String, major: String)?
    var cullingSummary: (visibleChunks: Int, totalChunks: Int, visibleSplats: Int)?

    var onRecenter: () -> Void
    var onBackgroundChange: (ViewerUIState.Background) -> Void
    var onReplace: () -> Void
    var onIndicatorsChange: (Bool) -> Void
    var onMeasuringTicksChange: (Bool) -> Void
    var onRulerUnitsChange: (RulerUnits) -> Void
    var onOcclusionChange: (Bool) -> Void
    var onQualityChange: (SplatQuality) -> Void

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
                Image(systemName: uiState.locksToSingleAxis ? "hand.point.up.left" : "hand.draw")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(uiState.locksToSingleAxis
                                        ? "Touch controls on, locked to one axis"
                                        : "Touch controls on")
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
                } else if let sourceCount = sceneState.sourceSplatCount {
                    Text("\(splatCount) of \(sourceCount) splats loaded")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if splatCount > SplatSceneState.performanceWarningSplatCount {
                    Label("^[\(splatCount) splat](inflect: true) — may run slowly",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.orange)
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
            gestureControls
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
                // Without this the gap between the title and the chevron isn't
                // tappable, so most of a full-width row does nothing.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if uiState.expandedSection == section {
                switch section {
                case .placement: scaleControls
                case .orientation: orientationControls
                case .position: positionControls
                case .display: displayControls
                case .performance: performanceControls
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
            Text("One finger up/down pushes it away or pulls it closer. Two-finger drag moves it sideways, or nudge:")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isPlacementAvailable {
                Button { onReplace() } label: {
                    Label("Re-place on a surface", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }

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

            Toggle("Position indicators", isOn: Binding(
                get: { uiState.showsPlacementIndicators },
                set: { onIndicatorsChange($0) }
            ))
            .font(.footnote)
            .disabled(!isPlacementAvailable)

            Text("Axis bars at the splat's center and outlines of detected surfaces. Turning this on enables surface detection, which costs performance.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if uiState.showsPlacementIndicators {
                measuringControls
            }

            Toggle("Hide splats behind surfaces", isOn: Binding(
                get: { uiState.occludesBehindSurfaces },
                set: { onOcclusionChange($0) }
            ))
            .font(.footnote)
            .disabled(!isOcclusionAvailable)

            Text(isOcclusionAvailable
                 ? "Splats behind a detected floor or table are hidden, so the splat looks like it's really in the room. Only as accurate as the detected surface."
                 : "Occlusion needs the camera background and a device with AR support.")
                .font(.caption2)
                .foregroundStyle(.secondary)

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

    /// The measuring stick: the notches are real-world sized whatever the
    /// splat's own units are, so pacing them off tells you how big it is.
    private var measuringControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Measuring notches", isOn: Binding(
                get: { uiState.showsMeasuringTicks },
                set: { onMeasuringTicksChange($0) }
            ))
            .font(.footnote)

            if uiState.showsMeasuringTicks {
                Picker("Units", selection: Binding(
                    get: { uiState.rulerUnits },
                    set: { onRulerUnitsChange($0) }
                )) {
                    ForEach(RulerUnits.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                .pickerStyle(.segmented)

                if let rulerDescription {
                    Text("Small notch \(rulerDescription.minor) · long notch \(rulerDescription.major)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 10)
    }

    // MARK: - Performance

    private var performanceControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Detail", selection: Binding(
                get: { uiState.quality },
                set: { onQualityChange($0) }
            )) {
                ForEach(SplatQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .disabled(sceneState.loadState.isLoading)

            Text("\(uiState.quality.detail) Changing this re-reads the file.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let cullingSummary {
                Label("\(cullingSummary.visibleChunks) of \(cullingSummary.totalChunks) chunks on screen · \(cullingSummary.visibleSplats) splats drawn",
                      systemImage: "square.grid.3x3")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("Splats off screen are skipped. Everything in view still costs full price — there's no occlusion between splats, so a dense capture is slow however close you stand.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Gestures

    private var gestureControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $uiState.areGesturesEnabled) {
                Label("Touch controls", systemImage: "hand.draw")
                    .font(.subheadline.weight(.medium))
            }

            if uiState.areGesturesEnabled {
                Toggle("Lock to one axis", isOn: $uiState.locksToSingleAxis)
                    .font(.footnote)

                Text("A two-finger gesture changes one thing: whichever of move, scale, or rotate you start with wins until you lift your fingers. Dragging also sticks to one direction.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }
}
