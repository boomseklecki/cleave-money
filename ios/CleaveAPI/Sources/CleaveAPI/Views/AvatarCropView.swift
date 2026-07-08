import SwiftUI
import UIKit

/// A rounded pinch-to-zoom crop for an avatar. Adapts `ZoomableReceiptViewer`'s gesture machinery (clamped
/// magnification + pan + double-tap) under a **circular mask** with a fixed square crop frame. On save it bakes
/// the transform into a 256×256 display square (served everywhere) and keeps the full-res original (for re-editing
/// past the crop). Reloadable: pass `initialCrop` to restore a prior transform so you can un-zoom past it.
struct AvatarCropView: View {
    let image: UIImage
    var title: String = "Move & Scale"
    /// Uploads the baked display + original + crop (the caller owns the network call, refresh, and cache bump).
    let onCommit: (_ display: Data, _ original: Data, _ crop: AvatarCrop) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat
    @State private var lastScale: CGFloat
    @State private var offset: CGSize
    @State private var lastOffset: CGSize
    @State private var saving = false
    @State private var errorText: String?

    /// Fixed on-screen crop side; `dx`/`dy` are stored normalized to this so the crop round-trips regardless of
    /// the image's size (a re-edit loads the ≤2048 original, not the original picked pixels).
    private let frameSide: CGFloat = 300

    init(image: UIImage, initialCrop: AvatarCrop? = nil, title: String = "Move & Scale",
         onCommit: @escaping (Data, Data, AvatarCrop) async throws -> Void) {
        self.image = image
        self.title = title
        self.onCommit = onCommit
        let s = max(1, CGFloat(initialCrop?.scale ?? 1))
        _scale = State(initialValue: s)
        _lastScale = State(initialValue: s)
        let off = CGSize(width: CGFloat(initialCrop?.dx ?? 0) * 300, height: CGFloat(initialCrop?.dy ?? 0) * 300)
        _offset = State(initialValue: off)
        _lastOffset = State(initialValue: off)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: frameSide, height: frameSide)   // aspect-fill baseline (overflow uncklipped)
                        .scaleEffect(scale)
                        .offset(offset)
                        .frame(width: frameSide, height: frameSide)    // container
                        .clipShape(Circle())                           // clip the crop to a circle
                    Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: frameSide, height: frameSide)
                }
                .frame(width: frameSide, height: frameSide)
                .contentShape(Rectangle())
                .gesture(magnification)
                .simultaneousGesture(pan)
                .onTapGesture(count: 2) { toggleZoom() }

                Text("Pinch to zoom · drag to move · double-tap to reset")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Use Photo", action: save) }
                }
            }
            .errorAlert($errorText)
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { scale = max(1, min(lastScale * $0, 6)) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in lastOffset = offset }
    }

    private func toggleZoom() {
        withAnimation {
            if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5 }
            lastScale = scale
        }
    }

    private func save() {
        guard let displayData = ReceiptImage.jpegData(bakeDisplay(), quality: 0.7),
              let originalData = ReceiptImage.jpegData(downscaledOriginal(), quality: 0.85) else {
            errorText = "Couldn't process the photo."
            return
        }
        let crop = AvatarCrop(scale: Double(scale),
                              dx: Double(offset.width / frameSide), dy: Double(offset.height / frameSide))
        saving = true
        Task {
            defer { saving = false }
            // The presenter closes this cover on success (Cancel dismisses it directly).
            do { try await onCommit(displayData, originalData, crop) }
            catch { errorText = errorMessage(error) }
        }
    }

    /// Render the current transform into a 256×256 square (matching the on-screen aspect-fill + scale + offset).
    private func bakeDisplay() -> UIImage {
        let side: CGFloat = 256
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let minDim = max(1, min(image.size.width, image.size.height))
            let drawScale = scale * side / minDim
            let drawSize = CGSize(width: image.size.width * drawScale, height: image.size.height * drawScale)
            let ox = side / 2 + offset.width * (side / frameSide) - drawSize.width / 2
            let oy = side / 2 + offset.height * (side / frameSide) - drawSize.height / 2
            image.draw(in: CGRect(x: ox, y: oy, width: drawSize.width, height: drawSize.height))
        }
    }

    /// The full, uncropped image capped at ~2048px (so re-editing can un-crop) - no transform applied.
    private func downscaledOriginal() -> UIImage {
        let maxDim: CGFloat = 2048
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDim else { return image }
        let f = maxDim / longest
        let newSize = CGSize(width: image.size.width * f, height: image.size.height * f)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
