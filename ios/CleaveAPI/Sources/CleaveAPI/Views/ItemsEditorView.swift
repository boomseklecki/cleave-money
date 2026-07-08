import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// Itemize a single bank/manual transaction: break its amount into line items, each with its own
/// category, so the Goals donut/budgets/Trends attribute the spend per item. Items can be typed in or
/// pulled from a scanned/photographed receipt (reusing the expense receipt pipeline). Saved via
/// `AccountRepository.setItems`. Only meaningful for outflows - the caller presents this for `amount > 0`.
/// Itemize an expense or a transaction: break its amount into line items, each with its own category, so the
/// Goals donut/budgets/Trends attribute the spend per item. Items can be typed in or pulled from a
/// scanned/photographed receipt. Saved via the owner's `setItems`. For a linked pair the caller passes the
/// canonical (expense) owner so there's one shared item set.
struct ItemsEditorView: View {
    let owner: ItemOwner
    /// Called when saving fails because the (pending) transaction no longer exists server-side - it posted.
    /// The parent surfaces the "already posted" prompt; we just dismiss.
    var onTransactionGone: () -> Void = {}

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \SpendCategory.position) private var spendCategories: [SpendCategory]

    @State private var items: [ItemDraft]
    @State private var categoryTarget: Int?
    @State private var receiptPhoto: PhotosPickerItem?
    @State private var showingScanner = false
    @State private var scan = ReceiptScanModel()
    @State private var aiAvailable = false
    @State private var categorizing = false
    @State private var saving = false
    @State private var errorText: String?

    init(owner: ItemOwner, onTransactionGone: @escaping () -> Void = {}) {
        self.owner = owner
        self.onTransactionGone = onTransactionGone
        _items = State(initialValue: owner.existingItemDrafts)
    }

    private var itemsTotal: Decimal { items.reduce(0) { $0 + $1.price } }
    private var remainder: Decimal { owner.amount - itemsTotal }
    private var overAmount: Bool { remainder < 0 }
    private var code: String { owner.currency }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(items.indices, id: \.self) { index in itemRow(index) }
                        .onDelete { items.remove(atOffsets: $0) }
                    Button { items.append(ItemDraft(name: "", price: 0)) } label: {
                        Label("Add Item", systemImage: "plus")
                    }
                } header: {
                    HStack {
                        Text("Items")
                        Spacer()
                        if aiAvailable {
                            AICategorizeButton(running: categorizing) { Task { await categorizeItems() } }
                                .disabled(items.allSatisfy { $0.name.isEmpty })
                        }
                    }
                } footer: {
                    totalsFooter
                }

                Section {
                    Button { showingScanner = true } label: {
                        Label("Scan Receipt", systemImage: "doc.viewfinder")
                    }
                    PhotosPicker(selection: $receiptPhoto, matching: .images) {
                        Label("Receipt from Photo", systemImage: "photo")
                    }
                } footer: {
                    Text("A receipt's items fill in below — review categories before saving.")
                }
            }
            .navigationTitle("Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(saving)
                }
            }
            .task { aiAvailable = ReceiptExtractor().isAvailable }
            .sheet(item: Binding(get: { categoryTarget.map { Indexed(id: $0) } },
                                 set: { categoryTarget = $0?.id })) { target in
                CategoryPickerView(current: items.indices.contains(target.id) ? items[target.id].category : nil,
                                   subject: itemSubject(target.id)) { picked in
                    if items.indices.contains(target.id) { items[target.id].category = picked }
                }
            }
            .sheet(isPresented: $showingScanner) {
                DocumentScannerView(
                    onComplete: { images in
                        showingScanner = false
                        if let first = images.first { Task { await appendFromReceipt(first) } }
                    },
                    onCancel: { showingScanner = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: receiptPhoto) { _, item in
                guard let item else { return }
                Task {
                    defer { receiptPhoto = nil }
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    await appendFromReceipt(image)
                }
            }
            .overlay {
                if scan.isScanning {
                    ProgressView("Reading receipt…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("Heads up", isPresented: Binding(
                get: { scan.infoMessage != nil }, set: { if !$0 { scan.infoMessage = nil } }
            )) { Button("OK") {} } message: { Text(scan.infoMessage ?? "") }
            .errorAlert(Binding(get: { scan.errorText }, set: { scan.errorText = $0 }))
            .errorAlert($errorText)
        }
    }

    /// One editable line item: name, price, and a category capsule.
    @ViewBuilder
    private func itemRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Item", text: itemBinding(index, \.name))
                Spacer()
                Text("$").foregroundStyle(.secondary)
                TextField("0.00", text: itemPriceBinding(index))
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 70)
            }
            Button { categoryTarget = index } label: {
                let category = items.indices.contains(index) ? items[index].category : nil
                HStack(spacing: 4) {
                    Image(systemName: categorySymbol(category)).font(.caption)
                    Text(category ?? "Category").font(.caption)
                        .foregroundStyle(category == nil ? .secondary : .primary)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    private var totalsFooter: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Items total")
                Spacer()
                Text(itemsTotal.formatted(.currency(code: code))).monospacedDigit()
            }
            HStack {
                Text(overAmount ? "Over amount" : "Remaining")
                Spacer()
                Text(remainder.formatted(.currency(code: code))).monospacedDigit()
            }
            .foregroundStyle(overAmount ? .red : .secondary)
        }
        .font(.caption)
    }

    private func itemSubject(_ index: Int) -> String? {
        guard items.indices.contains(index), !items[index].name.isEmpty else { return nil }
        return "Item: \(items[index].name)"
    }

    private func itemBinding(_ index: Int, _ keyPath: WritableKeyPath<ItemDraft, String>) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index][keyPath: keyPath] : "" },
            set: { if items.indices.contains(index) { items[index][keyPath: keyPath] = $0 } }
        )
    }
    private func itemPriceBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) && items[index].price != 0
                    ? Mapping.decimalString(items[index].price) : "" },
            set: { if items.indices.contains(index) { items[index].price = Self.decimal($0) } }
        )
    }

    private static func decimal(_ string: String?) -> Decimal {
        let text = (string ?? "").trimmingCharacters(in: .whitespaces)
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }

    /// Run the shared receipt pipeline and append its line items (ignoring its merchant/total/editor).
    private func appendFromReceipt(_ image: UIImage) async {
        await scan.process(image: image, categories: spendCategories.map(\.name))
        let drafts = (scan.prefill?.items ?? []).filter { !$0.name.isEmpty }
        // Drop any blank starter row before appending scanned items.
        items.removeAll { $0.name.isEmpty && $0.price == 0 }
        items.append(contentsOf: drafts)
    }

    private func categorizeItems() async {
        categorizing = true
        defer { categorizing = false }
        var idToIndex: [UUID: Int] = [:]
        var mapperItems: [CategoryMapper.Item] = []
        for (index, item) in items.enumerated() where !item.name.isEmpty {
            let tempId = UUID()
            idToIndex[tempId] = index
            mapperItems.append(.init(id: tempId, description: item.name, rawCategory: item.category,
                                     current: nil, note: owner.note))
        }
        let refined = await CategoryMapper.refine(mapperItems, allowed: spendCategories.map(\.name))
        for (id, category) in refined {
            if let index = idToIndex[id], items.indices.contains(index) { items[index].category = category }
        }
    }

    private func save() {
        saving = true
        let cleaned = items.filter { !$0.name.isEmpty || $0.price != 0 }
        let owner = self.owner
        Task {
            defer { saving = false }
            do {
                switch owner {
                case .transaction(let t):
                    try await env.accounts(context).setItems(id: t.id, items: cleaned)
                case .expense(let e):
                    try await env.expenses(context).setItems(id: e.id, items: cleaned,
                                                             updatedBy: env.currentUser?.identifier)
                }
                dismiss()
            } catch {
                if owner.isPendingTransaction, (error as? BackendError) == .notFound {
                    onTransactionGone()
                    dismiss()
                } else { errorText = errorMessage(error) }
            }
        }
    }
}

/// A tiny `Identifiable` index wrapper so an `Int` selection can drive a `.sheet(item:)`.
private struct Indexed: Identifiable { let id: Int }
