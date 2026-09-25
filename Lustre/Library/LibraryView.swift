//
//  LibraryView.swift
//  Lustre
//
//  The "Photos app" for splats: a grid of everything in `Documents/Splats/`,
//  with import, sort, and per-item rename / share / delete.
//
//  Opening a splat is a callback rather than a navigation link, so Library
//  doesn't reach into the Viewer — the App layer does the routing.
//

import SwiftUI

struct LibraryView: View {
    let library: SplatLibrary
    let onOpen: (SplatItem) -> Void
    let onOpenSample: () -> Void

    @AppStorage("library.sort") private var sort: LibrarySort = .dateAdded
    @State private var isImporting = false
    @State private var importFailures: [String] = []
    @State private var detailItem: SplatItem?
    @State private var renamingItem: SplatItem?
    @State private var pendingDeletion: SplatItem?
    @State private var actionError: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        content
            .navigationTitle("Library")
            .toolbar { toolbar }
            .refreshable { library.refresh() }
            .overlay {
                if library.isImporting {
                    ProgressView("Importing…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .fileImporter(isPresented: $isImporting,
                          allowedContentTypes: SplatFileIO.importableContentTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    Task { importFailures = await library.importFiles(urls) }
                case .failure(let error):
                    importFailures = [error.localizedDescription]
                }
            }
            .sheet(item: $detailItem) { item in
                SplatDetailSheet(item: item,
                                 onOpen: { current in detailItem = nil; onOpen(current) },
                                 onRename: { current, name in try library.rename(current, to: name) },
                                 onDelete: { current in try library.delete(current) })
            }
            .sheet(item: $renamingItem) { item in
                RenameSheet(item: item) { newName in
                    _ = try library.rename(item, to: newName)
                }
            }
            .confirmationDialog("Delete “\(pendingDeletion?.name ?? "")”?",
                                isPresented: isPresenting($pendingDeletion),
                                titleVisibility: .visible,
                                presenting: pendingDeletion) { item in
                Button("Delete", role: .destructive) { delete(item) }
            } message: { _ in
                Text(LibraryCopy.deleteWarning)
            }
            .alert("Some files weren't imported",
                   isPresented: Binding(get: { !importFailures.isEmpty },
                                        set: { if !$0 { importFailures = [] } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importFailures.joined(separator: "\n"))
            }
            .alert("Something went wrong",
                   isPresented: isPresenting($actionError),
                   presenting: actionError) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let storageError = library.storageError {
            ContentUnavailableView("Library unavailable",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(storageError))
        } else if library.items.isEmpty {
            ContentUnavailableView {
                Label("No splats yet", systemImage: "cube.transparent")
            } description: {
                Text("Import a PLY, SPZ, or .splat file, or add one to Lustre › Splats in the Files app.")
            } actions: {
                Button("Import Splats") { isImporting = true }
                    .buttonStyle(.borderedProminent)
                Button("Open Sample Room", action: onOpenSample)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(sort.sorted(library.items)) { item in
                        Button { onOpen(item) } label: {
                            SplatPreviewCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Open Sample Room", systemImage: "sparkles", action: onOpenSample)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }

            Button {
                isImporting = true
            } label: {
                Label("Import", systemImage: "plus")
            }
            .disabled(library.isImporting)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: SplatItem) -> some View {
        Button("Details", systemImage: "info.circle") { detailItem = item }
        Button("Rename", systemImage: "pencil") { renamingItem = item }
        ShareLink(item: item.url) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDeletion = item }
    }

    private func delete(_ item: SplatItem) {
        do {
            try library.delete(item)
        } catch {
            actionError = "Couldn't delete \(item.name): \(error.localizedDescription)"
        }
    }

    private func isPresenting<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil },
                set: { if !$0 { binding.wrappedValue = nil } })
    }
}
