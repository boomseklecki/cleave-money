import SwiftUI
import PhotosUI
import SwiftData
import UIKit

/// After a custom-avatar upload/delete, re-fetch the entity (so the resolved `avatar_url` / `has_custom_avatar`
/// update) and bump the avatar image cache so every on-screen `AvatarView` reloads.
@MainActor
func refreshAvatar(_ target: AvatarService.Target, env: AppEnvironment, context: ModelContext) async {
    switch target {
    case .me: await env.refreshCurrentUser(context)
    case .group(let id): try? await env.groups(context).refresh(id: id)
    }
    AvatarImageStore.shared.changed()
}

/// Downsample a picked/captured photo before it reaches the crop screen, so SwiftUI isn't handed a huge full-res
/// image (which can exhaust memory or blow the GPU texture limit and crash). It also becomes the ≤2048 "original"
/// kept for re-editing, so no meaningful detail is lost.
func downsampledForCrop(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
    let longest = max(image.size.width, image.size.height)
    guard longest > maxDimension else { return image }
    let f = maxDimension / longest
    let size = CGSize(width: image.size.width * f, height: image.size.height * f)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
}

/// Identifiable wrapper so a picked/captured image can drive an `item`-based cover (presented *after* the picker
/// dismisses, instead of swapping the navigation root mid-dismissal, which crashes).
struct PickedAvatarImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// A small camera glyph for the bottom-trailing of a tappable avatar, cueing tap-to-change. Overlay it via
/// `.overlay(alignment: .bottomTrailing) { AvatarCameraBadge() }`.
struct AvatarCameraBadge: View {
    var body: some View {
        Image(systemName: "camera.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
            .offset(x: 2, y: 2)
    }
}

/// The "add a custom avatar" flow: pick from Camera or Photo Library, then crop. The crop's commit uploads to the
/// target, refreshes the entity, and bumps the avatar cache. Presented as a sheet from Settings / a group header.
struct AddAvatarView: View {
    let target: AvatarService.Target
    var onDone: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showingCamera = false
    @State private var photo: PhotosPickerItem?
    @State private var cropping: PickedAvatarImage?

    var body: some View {
        NavigationStack {
            List {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showingCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                }
                PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
            }
            .navigationTitle("New Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker(onComplete: { image in
                showingCamera = false
                cropping = PickedAvatarImage(image: downsampledForCrop(image))
            }, onCancel: { showingCamera = false })
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $cropping) { picked in
            AvatarCropView(image: picked.image, onCommit: commit)
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                defer { photo = nil }
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    cropping = PickedAvatarImage(image: downsampledForCrop(image))
                }
            }
        }
    }

    private func commit(display: Data, original: Data, crop: AvatarCrop) async throws {
        try await AvatarService.upload(target, display: display, original: original, crop: crop)
        await refreshAvatar(target, env: env, context: context)
        cropping = nil
        onDone()
        dismiss()
    }
}
