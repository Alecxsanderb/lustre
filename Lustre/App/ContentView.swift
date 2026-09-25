//
//  ContentView.swift
//  Lustre
//
//  Created by Alec Borer on 6/24/26.
//
//  Navigation root and the only place features meet. Home and Library report
//  what the user picked through callbacks; this maps those onto routes and
//  builds the destination screens, so no feature references another.
//

import SwiftUI

struct ContentView: View {
    let library: SplatLibrary

    private enum Route: Hashable {
        case library
        case settings
        case viewer(ViewerContent)
    }

    @State private var path: [Route] = []
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(library: library,
                     onOpen: open,
                     onOpenSample: openSample,
                     onBrowseLibrary: { path.append(.library) },
                     onOpenSettings: { path.append(.settings) })
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .library:
                        LibraryView(library: library, onOpen: open, onOpenSample: openSample)
                    case .settings:
                        SettingsView(librarySizeInBytes: library.items.reduce(0) { $0 + $1.fileSize })
                    case .viewer(let content):
                        ViewerScreen(content: content,
                                     preferences: AppPreferences(reading: .standard))
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Files may have added or removed splats while we were away.
            if phase == .active { library.refresh() }
        }
    }

    private func open(_ item: SplatItem) {
        library.markOpened(item)
        path.append(.viewer(.file(item.url, name: item.name)))
    }

    private func openSample() {
        path.append(.viewer(.sample))
    }
}

#Preview {
    ContentView(library: SplatLibrary())
}
