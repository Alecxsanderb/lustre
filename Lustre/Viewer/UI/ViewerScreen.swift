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
                              cameraTransform: { model.cameraTransform })
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
                                cameraTransform: { model.cameraTransform },
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
                PlacementOverlay(candidate: model.placementCandidate,
                                 hasDetectedSurface: model.placementCandidate?.isOnSurface == true,
                                 onPlace: model.confirmPlacement)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            model.onAppear()
            if model.sceneState.loadState == .empty {
                await model.load(content)
            }
        }
        .onDisappear {
            model.onDisappear()
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
        ViewerScreen(content: .sample)
    }
}
