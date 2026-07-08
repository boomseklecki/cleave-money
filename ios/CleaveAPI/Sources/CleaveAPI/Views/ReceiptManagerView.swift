import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// The canonical item-bearing entity for a receipt owner - the expense when linked (only its items feed spend),
/// else the entity itself. Shared by the receipt Analyze action and the items editor.
enum ItemOwner {
    case expense(Expense)
    case transaction(Transaction)

    var id: UUID { switch self { case .expense(let e): e.id; case .transaction(let t): t.id } }
    var currency: String { switch self { case .expense(let e): e.currency; case .transaction(let t): t.currency } }
    var amount: Decimal { switch self { case .expense(let e): e.amount; case .transaction(let t): t.amount } }
    var note: String? { switch self { case .expense(let e): e.note; case .transaction(let t): t.note } }
    var isPendingTransaction: Bool { if case .transaction(let t) = self { t.pending } else { false } }
    var noun: String { if case .transaction = self { "transaction" } else { "expense" } }

    /// Existing items as drafts (id + owner preserved) so an analyze/edit upserts rather than replacing.
    var existingItemDrafts: [ItemDraft] {
        switch self {
        case .expense(let e):
            return e.items.map { ItemDraft(id: $0.id, name: $0.name, quantity: $0.quantity,
                                           price: $0.price, category: $0.category, owner: $0.ownerIdentifier) }
        case .transaction(let t):
            return t.items.map { ItemDraft(id: $0.id, name: $0.name, quantity: $0.quantity,
                                           price: $0.price, category: $0.category) }
        }
    }
}

/// Identifies the entity a receipt manager operates on - an expense or a transaction, plus its linked
/// counterpart (if any) so the manager shows the UNION of both sides' receipts and routes analyzed items to the
/// canonical (expense) side. Actions dispatch on this inside `ReceiptManagerView`.
enum ReceiptOwner {
    case expense(Expense, linkedTransaction: Transaction?)
    case transaction(Transaction, linkedExpense: Expense?)

    /// The linked expense (if any) - the side that owns shared items + the Splitwise receipt.
    private var expense: Expense? {
        switch self { case .expense(let e, _): e; case .transaction(_, let e): e }
    }
    private var allReceipts: [Receipt] {
        switch self {
        case .expense(let e, let t): e.receipts + (t?.receipts ?? [])
        case .transaction(let t, let e): t.receipts + (e?.receipts ?? [])
        }
    }
    var receipts: [Receipt] { allReceipts.sorted { $0.createdAt < $1.createdAt } }
    var firstReceipt: Receipt? { receipts.first }

    /// The view-only Splitwise receipt belongs to the (linked) expense.
    var splitwiseExpenseId: UUID? {
        if let e = expense, e.splitwiseReceiptURL != nil { return e.id }
        return nil
    }
    var hasReceipts: Bool { firstReceipt != nil || splitwiseExpenseId != nil }

    /// Analyzed items go to the canonical owner - the linked expense if present (only it feeds spend), else the
    /// primary entity.
    var canonicalItemTarget: ItemOwner {
        switch self {
        case .expense(let e, _): return .expense(e)
        case .transaction(let t, let e): return e.map(ItemOwner.expense) ?? .transaction(t)
        }
    }

    var noun: String { if case .transaction = self { "transaction" } else { "expense" } }
}

/// The header affordance shared by both detail screens: a camera/receipt glyph with a plus when there are no
/// receipts, else the first receipt's thumbnail. Tapping opens `ReceiptManagerView`.
struct ReceiptButton: View {
    let owner: ReceiptOwner
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let receipt = owner.firstReceipt {
                ReceiptThumbnail(receipt: receipt).modifier(HeaderThumbnailStyle())
            } else if let expenseId = owner.splitwiseExpenseId {
                SplitwiseReceiptThumbnail(expenseId: expenseId).modifier(HeaderThumbnailStyle())
            } else {
                Image(systemName: "doc.badge.plus").font(.title3).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(owner.hasReceipts ? "Receipts" : "Add receipt")
    }
}

/// Sizes a detail-header receipt thumbnail to match the 52×52 category icon (frameless thumbnails clip to it).
private struct HeaderThumbnailStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

/// A receipt manager (shared by the expense + transaction detail): view receipts, add more (scan or
/// photo), analyze a receipt to pull its line items in, and delete.
struct ReceiptManagerView: View {
    let owner: ReceiptOwner

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [SpendCategory]

    @State private var showingScanner = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var uploading = false
    @State private var analyzing: UUID?
    @State private var viewingPage: ReceiptPage?
    @State private var selection: String = ""
    @State private var errorText: String?

    private var pages: [ReceiptPage] {
        var out = owner.receipts.map(ReceiptPage.receipt)
        if let e = owner.splitwiseExpenseId { out.append(.splitwise(e)) }
        return out
    }
    private var currentPage: ReceiptPage? { pages.first { $0.id == selection } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if pages.isEmpty {
                    ContentUnavailableView {
                        Label("No receipts", systemImage: "doc.text.image")
                    } description: {
                        Text("Scan or add a photo of a receipt to itemize this \(owner.noun).")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    TabView(selection: $selection) {
                        ForEach(pages) { page in
                            ReceiptPageView(page: page) { openViewer(page) }
                                .padding(.horizontal)
                                .tag(page.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
                    .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    currentActions.padding(.horizontal)
                }
                addBar.padding([.horizontal, .bottom])
            }
            .navigationTitle("Receipts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView(
                    onComplete: { images in
                        showingScanner = false
                        Task { await upload(images.compactMap { ReceiptImage.jpegData($0) }) }
                    },
                    onCancel: { showingScanner = false }
                ).ignoresSafeArea()
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                Task {
                    defer { pickedPhoto = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let jpeg = ReceiptImage.jpegData(from: data) else { return }
                    await upload([jpeg])
                }
            }
            .fullScreenCover(item: $viewingPage) { page in
                ZoomableReceiptViewer(load: { await fullImage(for: page) })
            }
            .errorAlert($errorText)
            .onAppear { if currentPage == nil { selection = pages.first?.id ?? "" } }
            .onChange(of: pages.map(\.id)) { _, ids in
                if !ids.contains(selection) { selection = ids.first ?? "" }
            }
        }
    }

    /// Actions for the current page: Analyze + Delete for our receipts; view-only for the Splitwise one.
    @ViewBuilder private var currentActions: some View {
        switch currentPage {
        case .receipt(let r):
            HStack {
                Button { Task { await analyze(r) } } label: {
                    Label(analyzing == r.id ? "Reading…" : "Analyze", systemImage: "sparkles")
                }
                .disabled(analyzing != nil)
                Spacer()
                Button(role: .destructive) { Task { await delete(r) } } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        case .splitwise:
            Label("From Splitwise · view only", systemImage: "arrow.up.right.square")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .none:
            EmptyView()
        }
    }

    /// Add affordances - separate Scan + Photo controls (no collapsed menu).
    private var addBar: some View {
        HStack(spacing: 12) {
            Button { showingScanner = true } label: {
                Label(uploading ? "Uploading…" : "Scan Receipt", systemImage: "doc.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                Label("Receipt from Photo", systemImage: "photo").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .disabled(uploading)
    }

    /// Tapping any receipt image opens it full-screen (zoomable).
    private func openViewer(_ page: ReceiptPage) { viewingPage = page }

    /// The full-resolution image for the full-screen viewer (Splitwise fetches its "original").
    private func fullImage(for page: ReceiptPage) async -> UIImage? {
        switch page {
        case .receipt(let r): await ReceiptImageStore.shared.image(for: r.id, using: env.receipts(context))
        case .splitwise(let e): await SplitwiseReceiptImageStore.shared.image(expenseId: e, size: "original")
        }
    }

    private func upload(_ images: [Data]) async {
        guard !images.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        let (fails, err): (Int, Error?)
        switch owner {  // a new receipt attaches to the screen's own (primary) entity; it shows on both via the union
        case .transaction(let t, _): (fails, err) = await env.receipts(context).uploadMany(transactionId: t.id, images: images)
        case .expense(let e, _): (fails, err) = await env.receipts(context).uploadMany(expenseId: e.id, images: images)
        }
        if fails > 0 { errorText = err.map(errorMessage) ?? "Some receipts failed to upload." }
    }

    private func delete(_ receipt: Receipt) async {
        do {  // resolve the receipt's real owner (it may belong to the linked counterpart) and refresh that side
            if let e = receipt.expense {
                try await env.receipts(context).delete(receiptId: receipt.id, expenseId: e.id)
            } else if let t = receipt.transaction {
                try await env.receipts(context).delete(receiptId: receipt.id, transactionId: t.id)
            }
        } catch { errorText = errorMessage(error) }
    }

    /// Extract line items from the selected receipt (OCR → on-device extractor) and append them to the owner's
    /// items, preserving the existing ones.
    private func analyze(_ receipt: Receipt) async {
        analyzing = receipt.id
        defer { analyzing = nil }
        do {
            let data = try await env.receipts(context).imageData(receiptId: receipt.id)
            guard let image = UIImage(data: data) else { errorText = "Couldn't load the receipt image."; return }
            let scan = ReceiptScanModel()
            await scan.process(image: image, categories: categories.map(\.name))
            let newDrafts = (scan.prefill?.items ?? []).filter { !$0.name.isEmpty }
            guard !newDrafts.isEmpty else { errorText = "No line items found on that receipt."; return }
            let target = owner.canonicalItemTarget  // the linked expense when linked, else the primary
            let merged = target.existingItemDrafts + newDrafts
            switch target {
            case .transaction(let t):
                try await env.accounts(context).setItems(id: t.id, items: merged)
            case .expense(let e):
                try await env.expenses(context).setItems(id: e.id, items: merged, updatedBy: env.currentUser?.identifier)
            }
        } catch { errorText = errorMessage(error) }
    }
}

/// One page of the receipt carousel - a MinIO receipt (ours: view / analyze / delete) or the linked expense's
/// Splitwise receipt (view-only, no delete).
private enum ReceiptPage: Identifiable {
    case receipt(Receipt)
    case splitwise(UUID)
    var id: String {
        switch self { case .receipt(let r): r.id.uuidString; case .splitwise(let e): "sw-\(e.uuidString)" }
    }
}

/// A single large, aspect-fit receipt image for the carousel; tap to open the full-screen viewer. Loads a
/// MinIO receipt or a Splitwise receipt through the same stores the thumbnails use.
private struct ReceiptPageView: View {
    let page: ReceiptPage
    var onTap: () -> Void

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    var body: some View {
        AsyncCachedImage(mode: .fit, load: loadImage) {
            ContentUnavailableView("Couldn't load receipt", systemImage: "doc.text.image")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private func loadImage() async -> UIImage? {
        switch page {
        case .receipt(let r): await ReceiptImageStore.shared.image(for: r.id, using: env.receipts(context))
        case .splitwise(let e): await SplitwiseReceiptImageStore.shared.image(expenseId: e, size: "original")
        }
    }
}
