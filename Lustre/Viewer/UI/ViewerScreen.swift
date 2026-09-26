//
//  ViewerScreen.swift
//  Lustre
//
//  The walk-through experience. Composes the Metal view, the gesture layer,
//  the control menu, and — when the pose is simulated — the joysticks.
//
//  ZStack order matters: gestures sit directly above the render view, and
//  everything with its own touch handling (joysticks, menu) sits above them so
//  it wins by being on top.
//

import SwiftUI

struct ViewerScreen: View {
    let content: ViewerContent
    /// A snapshot taken when the Viewer opens. Settings can't be reached from
    /// here, so nothing changes it *during* a session; the Viewer's own
    /// display changes go out through `onDisplayChange` instead.
    let preferences: AppPreferences
    /// Called when the user changes a remembered display setting, with the
    /// whole set. Not called for the values applied at open.
    let onDisplayChange: (AppPreferences.ViewerDisplay) -> Void

    @State private var model = ViewerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                SplatRenderView(renderer: renderer)
                    .ignoresSafeArea()
            }

            SplatGestureLayer(sceneState: model.sceneState,
                              isEnabled: model.uiState.areGesturesEnabled
                                  && !model.sceneState.loadState.isLoading,
                              locksToSingleAxis: model.uiState.locksToSingleAxis,
                              makeBasis: model.makeGestureBasis)
                .ignoresSafeArea()

            if let initializationError = model.initializationError {
                ContentUnavailableView("Can't render splats",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(initializationError))
            }

            VStack {
                Spacer()

                if let simulatedProvider = model.simulatedProvider {
                    SimulatorControlsOverlay(provider: simulatedProvider)
                }

                // The menu would compete with the placement step for the same
                // corner, and placement is modal by nature.
                if !model.isAwaitingPlacement {
                    ControlMenu(sceneState: model.sceneState,
                                uiState: model.uiState,
                                statusMessage: model.statusMessage,
                                isPassthroughAvailable: model.isPassthroughAvailable,
                                isPlacementAvailable: model.isPlacementAvailable,
                                isOcclusionAvailable: model.isOcclusionAvailable,
                                rulerDescription: model.rulerDescription,
                                cullingSummary: model.cullingSummary,
                                makeBasis: model.makeGestureBasis,
                                onRecenter: model.recenter,
                                onBackgroundChange: model.setBackground,
                                onReplace: model.beginPlacement,
                                onIndicatorsChange: model.setIndicatorsEnabled,
                                onMeasuringTicksChange: model.setMeasuringTicksEnabled,
                                onRulerUnitsChange: model.setRulerUnits,
                                onOcclusionChange: model.setOcclusionEnabled,
                                onQualityChange: { quality in
                                    Task { await model.setQuality(quality) }
                                })
                        .padding(.bottom, 8)
                }
            }

            if model.isAwaitingPlacement {
                PlacementOverlay(readiness: model.placementReadiness,
                                 statusMessage: model.statusMessage,
                                 onPlace: model.confirmPlacement)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Once per model: if the task ever reruns, re-applying the
            // snapshot would undo this session's changes.
            if model.persistedDisplay == nil {
                model.apply(preferences)
            }
            model.onAppear()
            if model.sceneState.loadState == .empty {
                await model.load(content)
            }
        }
        .onDisappear {
            model.onDisappear()
        }
        // The first change, nil to the applied values, is `apply` itself and
        // is skipped: only a user change writes back. (If SwiftUI ever first
        // observes the applied value directly, no change fires at all, so
        // either way opening a splat writes nothing.)
        .onChange(of: model.persistedDisplay) { old, new in
            guard old != nil, let new else { return }
            onDisplayChange(new)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.onEnterBackground()
            case .active: model.onBecomeActive()
            // Inactive is transient (Control Center, the app switcher peek);
            // tearing down tracking for it would cost a relocalization.
            case .inactive: break
            @unknown default: break
            }
        }
    }

    private var title: String {
        switch content {
        case .sample: "Sample Room"
        case .file(_, let name): name
        }
    }
}

#Preview {
    NavigationStack {
        ViewerScreen(content: .sample, preferences: .defaults, onDisplayChange: { _ in })
    }
}
