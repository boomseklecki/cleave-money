import SwiftUI
import UIKit

/// Manage an existing custom avatar (user or group): **Edit** re-crops the full-res original (seeded with the
/// saved crop, so you can un-zoom past it), **Choose New Photo** replaces it, and **Delete** reverts to the
/// external Splitwise/Google avatar. Presented when `has_custom_avatar` is true.
struct AvatarManageView: View {
    let target: AvatarService.Target
    var crop: AvatarCrop?
    var onDone: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing: PickedAvatarImage?
    @State private var loadingOriginal = false
    @State private var showingReplace = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: loadOriginalAndEdit) {
                        HStack {
                            Label("Edit Photo", systemImage: "crop")
                            Spacer()
                            if loadingOriginal { ProgressView() }
                        }
                    }
                    .disabled(loadingOriginal)
                    Button { showingReplace = true } label: {
                        Label("Choose New Photo", systemImage: "photo.on.rectangle")
                    }
                }
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        HStack {
                            Label("Delete Photo", systemImage: "trash")
                            Spacer()
                            if deleting { ProgressView() }
                        }
                    }
                    .disabled(deleting)
                } footer: {
                    Text("Removes the custom photo and reverts to the Splitwise/Google avatar.")
                }
            }
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .fullScreenCover(item: $editing) { picked in
            AvatarCropView(image: picked.image, initialCrop: crop, title: "Edit Photo", onCommit: commit)
        }
        .sheet(isPresented: $showingReplace) {
            AddAvatarView(target: target) { onDone(); dismiss() }
        }
        .confirmationDialog("Delete photo?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: deleteAvatar)
            Button("Cancel", role: .cancel) {}
        }
        .errorAlert($errorText)
    }

    private func loadOriginalAndEdit() {
        loadingOriginal = true
        Task {
            defer { loadingOriginal = false }
            do {
                let data = try await AvatarService.original(target)
                if let image = UIImage(data: data) {
                    editing = PickedAvatarImage(image: downsampledForCrop(image))
                } else {
                    errorText = "Couldn't load the photo."
                }
            } catch { errorText = errorMessage(error) }
        }
    }

    private func commit(display: Data, original: Data, crop: AvatarCrop) async throws {
        try await AvatarService.upload(target, display: display, original: original, crop: crop)
        await refreshAvatar(target, env: env, context: context)
        editing = nil
        onDone()
        dismiss()
    }

    private func deleteAvatar() {
        deleting = true
        Task {
            defer { deleting = false }
            do {
                try await AvatarService.delete(target)
                await refreshAvatar(target, env: env, context: context)
                onDone()
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}
