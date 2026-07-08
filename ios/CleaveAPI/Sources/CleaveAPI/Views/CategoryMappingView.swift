import SwiftUI
import SwiftData

/// Remap the raw Bank (Plaid) categories to the app's canonical categories. Offers an on-device
/// (Apple Intelligence) pass for unmapped/vague labels, plus a manual picker per row.
struct BankCategoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query private var transactions: [Transaction]
    @Query private var categoryMaps: [CategoryMap]
    @Query(sort: \SpendCategory.position) private var categoryModels: [SpendCategory]

    @State private var mapping = false
    @State private var editing: EditingRaw?
    @State private var errorText: String?

    private struct EditingRaw: Identifiable { let id: String }

    /// Distinct raw categories seen on Plaid transactions.
    private var rawCategories: [String] {
        let raws = transactions.filter { $0.source == .plaid }.compactMap { $0.category }
        return Set(raws).sorted()
    }
    private var mapByRaw: [String: CategoryMap] {
        Dictionary(categoryMaps.map { ($0.rawCategory, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private func resolved(_ raw: String) -> (canonical: String?, source: String) {
        if let m = mapByRaw[raw] { return (m.canonicalCategory, m.source) }
        if let auto = PlaidCategory.canonical(raw) { return (auto, "auto") }
        return (nil, "unmapped")
    }
    private func currentCanonical(_ raw: String) -> String? {
        mapByRaw[raw]?.canonicalCategory ?? PlaidCategory.canonical(raw)
    }
    private var unmappedCount: Int { rawCategories.filter { resolved($0).source == "unmapped" }.count }
    private var refinable: [Transaction] {
        let lookup = CategoryMapping.lookup(categoryMaps)
        return transactions.filter {
            $0.refinedCategory == nil && CategoryMapping.needsRefinement($0, lookup: lookup)
        }
    }

    var body: some View {
        List {
            if CategoryMapper.isAvailable {
                let pending = unmappedCount + refinable.count
                Section {
                    Button { Task { await runOnDevice() } } label: {
                        Label(mapping ? "Categorizing…" : "Categorize with Apple Intelligence",
                              systemImage: "sparkles")
                    }
                    .disabled(mapping || pending == 0)
                } footer: {
                    Text("On-device: maps \(unmappedCount) unmapped label\(unmappedCount == 1 ? "" : "s") and refines \(refinable.count) vague transaction\(refinable.count == 1 ? "" : "s") from their merchant. Your manual choices are kept.")
                }
            }
            Section {
                if rawCategories.isEmpty {
                    Text("No Plaid transactions yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(rawCategories, id: \.self) { raw in
                    Button { editing = EditingRaw(id: raw) } label: {
                        mappingRow(label: PlaidCategory.humanized(raw), resolution: resolved(raw))
                    }
                }
            } footer: {
                Text("How your bank transaction categories map into your spending categories.")
            }
        }
        .navigationTitle("Bank Categories")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { item in
            CategoryPickerView(current: currentCanonical(item.id), subject: PlaidCategory.humanized(item.id)) {
                setManual(env: env, context: context, raw: item.id, canonical: $0, errorText: $errorText)
            }
        }
        .errorAlert($errorText)
    }

    private func runOnDevice() async {
        mapping = true
        defer { mapping = false }
        let unmapped = rawCategories.filter { resolved($0).source == "unmapped" }
        let allowed = categoryModels.map(\.name)
        let suggestions = await CategoryMapper.suggest(for: unmapped, allowed: allowed)
        do {
            try await env.categoryMaps(context).setMany(
                suggestions.map { (raw: $0.key, canonical: $0.value) }, source: "ondevice")
        } catch { errorText = errorMessage(error) }
        let items = refinable.map {
            CategoryMapper.Item(id: $0.id, description: $0.details, rawCategory: $0.category, current: nil,
                                note: $0.note)
        }
        let refined = await CategoryMapper.refine(items, allowed: allowed)
        guard !refined.isEmpty else { return }
        for transaction in transactions where refined[transaction.id] != nil {
            transaction.refinedCategory = refined[transaction.id]
        }
        do { try context.save() } catch { errorText = errorMessage(error) }
        // Mirror the new refinements to the backend so this user's other devices inherit them.
        let entries = refined.map { (id: $0.key, refined: $0.value) }
        try? await env.accounts(context).setRefinedCategory(entries)
    }
}

/// Remap imported Splitwise category names to the app's canonical categories (manual picker per row).
struct SplitwiseCategoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context

    @Query private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]
    @Query(sort: \SpendCategory.position) private var categoryModels: [SpendCategory]

    @State private var mapping = false
    @State private var editing: EditingRaw?
    @State private var errorText: String?

    private struct EditingRaw: Identifiable { let id: String }
    private var unmappedCount: Int { splitwiseCategories.filter { resolved($0).source == "unmapped" }.count }

    private var splitwiseCategories: [String] {
        let raws = expenses
            .filter { $0.splitwiseExpenseId != nil }
            .compactMap { $0.category }
            .filter { !$0.isEmpty && $0 != SettleUp.category && $0 != Reimbursement.category }
        return Set(raws).sorted()
    }
    private var mapByRaw: [String: CategoryMap] {
        Dictionary(categoryMaps.map { ($0.rawCategory, $0) }, uniquingKeysWith: { a, _ in a })
    }
    private func resolved(_ raw: String) -> (canonical: String?, source: String) {
        if let m = mapByRaw[raw] { return (m.canonicalCategory, m.source) }
        if let auto = SplitwiseCategory.canonical(raw) { return (auto, "auto") }
        return (nil, "unmapped")
    }
    private func currentCanonical(_ raw: String) -> String? {
        mapByRaw[raw]?.canonicalCategory ?? SplitwiseCategory.canonical(raw)
    }

    /// On-device pass: classify any Splitwise category names the deterministic map doesn't cover.
    private func runOnDevice() async {
        mapping = true
        defer { mapping = false }
        let unmapped = splitwiseCategories.filter { resolved($0).source == "unmapped" }
        let suggestions = await CategoryMapper.suggest(for: unmapped, allowed: categoryModels.map(\.name))
        do {
            try await env.categoryMaps(context).setMany(
                suggestions.map { (raw: $0.key, canonical: $0.value) }, source: "ondevice")
        } catch { errorText = errorMessage(error) }
    }

    var body: some View {
        List {
            if CategoryMapper.isAvailable {
                Section {
                    Button { Task { await runOnDevice() } } label: {
                        Label(mapping ? "Categorizing…" : "Categorize with Apple Intelligence",
                              systemImage: "sparkles")
                    }
                    .disabled(mapping || unmappedCount == 0)
                } footer: {
                    Text("On-device: maps \(unmappedCount) unmapped Splitwise categor\(unmappedCount == 1 ? "y" : "ies"). Your manual choices are kept.")
                }
            }
            Section {
                if splitwiseCategories.isEmpty {
                    Text("No Splitwise expenses yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(splitwiseCategories, id: \.self) { raw in
                    Button { editing = EditingRaw(id: raw) } label: {
                        mappingRow(label: raw, resolution: resolved(raw))
                    }
                }
            } footer: {
                Text("How imported Splitwise categories map into your spending categories.")
            }
        }
        .navigationTitle("Splitwise Categories")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { item in
            CategoryPickerView(current: currentCanonical(item.id), subject: item.id) {
                setManual(env: env, context: context, raw: item.id, canonical: $0, errorText: $errorText)
            }
        }
        .errorAlert($errorText)
    }
}

// MARK: - Shared

/// One source→canonical mapping row: the source label, its resolved canonical + source icon, chevron.
@ViewBuilder
func mappingRow(label: String, resolution: (canonical: String?, source: String)) -> some View {
    HStack(spacing: 10) {
        Text(label).foregroundStyle(.primary)
        Spacer()
        if let canonical = resolution.canonical {
            if let icon = mappingSourceIcon(resolution.source) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(canonical).foregroundStyle(.secondary)
        } else {
            Text("Unmapped").foregroundStyle(.tertiary)
        }
        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
    }
}

func mappingSourceIcon(_ source: String) -> String? {
    switch source {
    case "manual": return "hand.point.up.left"
    case "ondevice": return "sparkles"
    case "auto": return "wand.and.stars"
    default: return nil
    }
}

@MainActor
private func setManual(env: AppEnvironment, context: ModelContext, raw: String, canonical: String,
                       errorText: Binding<String?>) {
    Task {
        do { try await env.categoryMaps(context).set(raw: raw, canonical: canonical, source: "manual") }
        catch { errorText.wrappedValue = errorMessage(error) }
    }
}
