//
//  LustreApp.swift
//  Lustre
//
//  Created by Alec Borer on 6/24/26.
//

import SwiftUI

@main
struct LustreApp: App {
    /// One library for the app's lifetime; Home and Library both read it.
    @State private var library = SplatLibrary()
    /// One generator and memory cache for every thumbnail on screen.
    @State private var thumbnails = ThumbnailStore()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .environment(\.thumbnailStore, thumbnails)
        }
    }
}
