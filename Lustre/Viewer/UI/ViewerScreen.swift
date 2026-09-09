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
    @State private var model = ViewerModel()
    @State private var isImporting = false

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

                ControlMenu(sceneState: model.sceneState,
                            uiState: model.uiState,
                            statusMessage: model.statusMessage,
                            isPassthroughAvailable: model.isPassthroughAvailable,
                            onRecenter: model.recenter,
                            onBackgroundChange: model.setBackground)
                    .padding(.bottom, 8)
            }
        }
        .navigationTitle("Viewer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    isImporting = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(model.sceneState.loadState.isLoading)
            }
        }
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: SplatFileIO.importableContentTypes) { result in
            switch result {
            case .success(let url):
                Task { await model.load(url: url) }
            case .failure(let error):
                model.sceneState.loadState = .failed(error.localizedDescription)
            }
        }
        .task {
            model.onAppear()
            // Something on screen from the first frame, so the viewer is never
            // a blank rectangle. Replaced by the Library in build order step 2.
            if model.sceneState.loadState == .empty {
                await model.loadSample()
            }
        }
        .onDisappear {
            model.onDisappear()
        }
    }
}

#Preview {
    NavigationStack {
        ViewerScreen()
    }
}
