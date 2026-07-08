import SwiftUI
import SwiftData
import UIKit

/// In-memory cache of decoded receipt images (bytes come from the API `/receipts/{id}/content`).
@MainActor
final class ReceiptImageStore {
    static let shared = ReceiptImageStore()
    private let store = CacheImageStore<NSUUID>()

    func image(for receiptId: UUID, using repository: ReceiptRepository) async -> UIImage? {
        await store.image(for: receiptId as NSUUID) {
            guard let data = try? await repository.imageData(receiptId: receiptId) else { return nil }
            return UIImage(data: data)
        }
    }
}

/// Loads Splitwise receipt images through our backend proxy (`/splitwise/expenses/{id}/receipt`), attaching the
/// bearer token. The proxy is auth-gated and its OpenAPI declares the 200 as JSON, so it can go through neither
/// the generated client nor a bare `AsyncImage` (neither sends the token).
@MainActor
final class SplitwiseReceiptImageStore {
    static let shared = SplitwiseReceiptImageStore()
    private let store = CacheImageStore<NSString>()

    func image(expenseId: UUID, size: String? = nil) async -> UIImage? {
        let key = "\(expenseId.uuidString)#\(size ?? "")" as NSString
        return await store.image(for: key) {
            let base = APIConfig.baseURL.appendingPathComponent("splitwise/expenses/\(expenseId.uuidString)/receipt")
            guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
            if let size { components.queryItems = [URLQueryItem(name: "size", value: size)] }
            guard let url = components.url else { return nil }

            var request = URLRequest(url: url)
            // Per-server token slot - same one the generated client uses; the legacy global slot is emptied by
            // migration, so `KeychainTokenStore()` here sent no auth → the protected proxy 401'd.
            if let token = KeychainTokenStore.forServer(APIConfig.baseURL).load(), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
            return UIImage(data: data)
        }
    }
}

private var receiptFallback: some View { Image(systemName: "doc.text.image").foregroundStyle(.secondary) }

/// A receipt thumbnail image (frameless - the caller sizes and clips it), loaded from the API and cached.
struct ReceiptThumbnail: View {
    let receipt: Receipt
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    var body: some View {
        AsyncCachedImage(mode: .fill,
                         load: { await ReceiptImageStore.shared.image(for: receipt.id, using: env.receipts(context)) }) {
            receiptFallback
        }
    }
}

/// A Splitwise receipt thumbnail (frameless - the caller sizes it), loaded through the authenticated proxy.
struct SplitwiseReceiptThumbnail: View {
    let expenseId: UUID

    var body: some View {
        AsyncCachedImage(mode: .fill,
                         load: { await SplitwiseReceiptImageStore.shared.image(expenseId: expenseId) }) {
            receiptFallback
        }
    }
}

/// Full-screen receipt viewer with pinch-to-zoom, drag-to-pan (when zoomed), and double-tap to toggle - 
/// generic over how the image loads, so it serves both our own and Splitwise receipts.
struct ZoomableReceiptViewer: View {
    let load: () async -> UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            AsyncCachedImage(mode: .fit, load: load) {
                ContentUnavailableView("Couldn't load receipt", systemImage: "doc.text.image")
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = max(1, min(lastScale * $0, 6)) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1 { scale = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5 }
                    lastScale = scale
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
