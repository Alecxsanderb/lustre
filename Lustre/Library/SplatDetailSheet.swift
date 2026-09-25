//
//  SplatDetailSheet.swift
//  Lustre
//
//  Metadata and actions for one splat.
//

import SwiftUI

struct SplatDetailSheet: View {
    let onOpen: (SplatItem) -> Void
    /// Returns the renamed item, whose URL has changed.
    let onRename: (SplatItem, String) throws -> SplatItem
    let onDelete: (SplatItem) throws -> Void

    /// Local copy so a rename updates the sheet in place.
    @State private var item: SplatItem
    @State private var isRenaming = false
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(item: SplatItem,
         onOpen: @escaping (SplatItem) -> Void,
         onRename: @escaping (SplatItem, String) throws -> SplatItem,
         onDelete: @escaping (SplatItem) throws -> Void) {
        _item = State(initialValue: item)
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Capped so the metadata is visible at the medium detent.
                    SplatThumbnailPlaceholder(item: item)
                        .frame(height: 140)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    LabeledContent("Format", value: item.formatLabel)
                    LabeledContent("Size", value: item.fileSize.formatted(.byteCount(style: .file)))
                    LabeledContent("Added", value: item.dateAdded.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Source", value: item.source == .captured ? "Captured" : "Imported")
                    if let lastOpened = item.lastOpened {
                        LabeledContent("Last opened",
                                       value: lastOpened.formatted(.relative(presentation: .named)))
                    }
                }

                Section {
                    Button("Open in Viewer", systemImage: "cube.transparent") { onOpen(item) }
                    Button("Rename", systemImage: "pencil") { isRenaming = true }
                    ShareLink(item: item.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }

                Section {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $isRenaming) {
            RenameSheet(item: item) { newName in
                item = try onRename(item, newName)
            }
        }
        .confirmationDialog("Delete “\(item.name)”?",
                            isPresented: $isConfirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try onDelete(item)
                    dismiss()
                } catch {
                    errorMessage = "Couldn't delete: \(error.localizedDescription)"
                }
            }
        } message: {
            Text(LibraryCopy.deleteWarning)
        }
    }
}

enum LibraryCopy {
    static let deleteWarning = "The file is removed from this iPhone. This can't be undone."
}

/// Text field sheet for renaming. The rename runs here so a collision or bad
/// name keeps the sheet up with the error, instead of dismissing and losing
/// what was typed.
struct RenameSheet: View {
    let item: SplatItem
    let onRename: (String) throws -> Void

    @State private var name: String
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(item: SplatItem, onRename: @escaping (String) throws -> Void) {
        self.item = item
        self.onRename = onRename
        _name = State(initialValue: item.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(commit)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: commit)
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private func commit() {
        do {
            try onRename(name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
