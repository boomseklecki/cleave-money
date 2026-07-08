import SwiftUI
import SwiftData

/// Add, rename, delete, and re-icon the canonical categories (full control - built-ins included).
/// A category can't be deleted while source categories (Bank/Splitwise) map to it - through a manual
/// override or the built-in deterministic maps. The dependents sheet lists those and lets you reassign.
struct ManageCategoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Query(sort: \SpendCategory.position) private var categories: [SpendCategory]
    @Query private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]

    @State private var sheet: Sheet?
    @State private var errorText: String?
    @State private var syncing = false
    @AppStorage("debug.categoryProvenance") private var showCategorySource = false

    private enum Sheet: Identifiable {
        case edit(SpendCategory?)
        case dependents(SpendCategory)
        var id: String {
            switch self {
            case let .edit(c): "edit-\(c?.id.uuidString ?? "new")"
            case let .dependents(c): "deps-\(c.id.uuidString)"
            }
        }
    }

    var body: some View {
        // Reverse map (canonical → source labels) built once per render, not per row.
        let dependents = CategoryDependents.grouped(transactions: transactions, expenses: expenses,
                                                    categoryMaps: categoryMaps)
        return List {
            Section {
                ForEach(categories) { category in
                    Button { sheet = .edit(category) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.displaySymbol)
                                .foregroundStyle(categoryColor(category.name)).frame(width: 26)
                            Text(category.name).foregroundStyle(.primary)
                            Spacer()
                            let used = dependents[category.name]?.count ?? 0
                            if used > 0 { Text("\(used)").font(.caption2).foregroundStyle(.tertiary) }
                            if category.builtin {
                                Text("Built-in").font(.caption2).foregroundStyle(.tertiary)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                .onDelete { offsets in delete(offsets, dependents: dependents) }
            } header: {
                Text("Categories")
            } footer: {
                Text("Add your own categories or rename/delete any. A category can't be deleted while Bank or Splitwise categories map to it — tap it to reassign those first.")
            }

            Section("Mappings") {
                NavigationLink {
                    BankCategoriesView()
                } label: {
                    Label("Bank Categories", systemImage: "building.columns")
                }
                NavigationLink {
                    SplitwiseCategoriesView()
                } label: {
                    Label("Splitwise Categories", systemImage: "person.2")
                }
            }

            Section {
                Toggle(isOn: $showCategorySource) {
                    Label("Show Category Source", systemImage: "tag.circle")
                }
            } footer: {
                Text("Show where each category came from (your override, an on-device AI refinement, a mapping, "
                     + "or the built-in rule) on the transaction and expense detail screens.")
            }

            Section {
                Button(action: syncNow) {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if syncing { ProgressView() }
                    }
                }
                .disabled(syncing)
            } footer: {
                Text("Your categories sync with your account, so they're on all your devices. Sync now to pick "
                     + "up changes made on another device."
                     + (CategorySync.lastSyncedAt.map { " Last synced \($0.formatted(.relative(presentation: .named)))." } ?? ""))
            }
        }
        .navigationTitle("Category Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .edit(nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case let .edit(category): CategoryEditView(editing: category)
            case let .dependents(category): CategoryDependentsView(category: category)
            }
        }
        .errorAlert($errorText)
    }

    private func syncNow() {
        syncing = true
        Task {
            await env.syncCategoriesNow(context)
            syncing = false
        }
    }

    private func delete(_ offsets: IndexSet, dependents: [String: [CategoryDependent]]) {
        for category in offsets.map({ categories[$0] }) {
            if dependents[category.name]?.isEmpty == false {
                sheet = .dependents(category)  // reassign the mappings first
                return
            }
            let id = category.id
            Task {
                do { try await env.categories(context).delete(id: id) }
                catch { errorText = errorMessage(error) }
            }
        }
    }
}

/// Lists the source categories (Bank/Splitwise) that resolve to `category`, each reassignable, and
/// allows deleting the category once none remain.
struct CategoryDependentsView: View {
    let category: SpendCategory

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]
    @State private var errorText: String?

    private var dependents: [CategoryDependent] {
        CategoryDependents.of(category.name, transactions: transactions, expenses: expenses,
                              categoryMaps: categoryMaps)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if dependents.isEmpty {
                        Text("No Bank or Splitwise categories map here anymore.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(dependents) { MappingReassignRow(dependent: $0, currentCanonical: category.name) }
                } header: {
                    Text("Mapped to \(category.name)")
                } footer: {
                    Text(dependents.isEmpty
                         ? "You can delete “\(category.name)” now."
                         : "Reassign each of these to another category to delete “\(category.name)”.")
                }
            }
            .navigationTitle("Used by \(dependents.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete", role: .destructive, action: deleteNow).disabled(!dependents.isEmpty)
                }
            }
            .errorAlert($errorText)
        }
    }

    private func deleteNow() {
        let id = category.id
        Task {
            do { try await env.categories(context).delete(id: id); dismiss() }
            catch { errorText = errorMessage(error) }
        }
    }
}

/// One source→canonical mapping, tappable to reassign it (writes/updates a `category_map` override).
struct MappingReassignRow: View {
    let dependent: CategoryDependent
    let currentCanonical: String

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @State private var picking = false
    @State private var pendingCanonical: String?
    @State private var errorText: String?

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: 10) {
                Image(systemName: dependent.icon)
                    .font(.caption2).foregroundStyle(.tertiary).frame(width: 18)
                Text(dependent.label).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .sheet(isPresented: $picking) {
            CategoryPickerView(current: currentCanonical, subject: dependent.label) { chosen in
                if chosen != currentCanonical { pendingCanonical = chosen }
            }
        }
        // Confirm before moving it - otherwise the row silently leaves this category's list.
        .confirmationDialog(
            pendingCanonical.map { "Map “\(dependent.label)” to “\($0)”?" } ?? "",
            isPresented: Binding(get: { pendingCanonical != nil },
                                 set: { if !$0 { pendingCanonical = nil } }),
            titleVisibility: .visible
        ) {
            if let target = pendingCanonical {
                Button("Map to \(target)") { reassign(to: target); pendingCanonical = nil }
            }
            Button("Cancel", role: .cancel) { pendingCanonical = nil }
        }
        .errorAlert($errorText)
    }

    private func reassign(to canonical: String) {
        let raw = dependent.raw
        Task {
            do { try await env.categoryMaps(context).set(raw: raw, canonical: canonical, source: "manual") }
            catch { errorText = errorMessage(error) }
        }
    }
}

/// Create or edit one category: name + a grid of SF Symbol icons, plus the source categories that map here.
struct CategoryEditView: View {
    let editing: SpendCategory?  // nil = create

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [Transaction]
    @Query private var expenses: [Expense]
    @Query private var categoryMaps: [CategoryMap]

    @State private var name: String
    @State private var icon: String
    @State private var color: String?
    @State private var showingIconGrid = false
    @State private var iconQuery = ""
    @State private var saving = false
    @State private var errorText: String?

    init(editing: SpendCategory?) {
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _icon = State(initialValue: editing?.icon ?? "tag")
        _color = State(initialValue: editing?.color)
    }

    /// The chosen color, or the deterministic palette color when none is set.
    private var chosenColor: Color { Color(hex: color) ?? categoryPaletteColor(name) }

    /// Bridges the stored hex `color` to the system `ColorPicker`: it reads the current color (falling back to
    /// the palette) and writes the picked color back as a hex string ("#RRGGBB" / "#RRGGBBAA").
    private var customColorBinding: Binding<Color> {
        Binding(get: { chosenColor }, set: { color = $0.hexString() })
    }

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving }
    private var iconResults: [IconChoice] { CategoryIconLibrary.search(iconQuery) }
    private var dependents: [CategoryDependent] {
        guard let editing else { return [] }
        return CategoryDependents.of(editing.name, transactions: transactions, expenses: expenses,
                                     categoryMaps: categoryMaps)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Button { withAnimation { showingIconGrid.toggle() } } label: {
                            Image(systemName: icon)
                                .font(.system(size: 30))
                                .foregroundStyle(chosenColor)
                                .frame(width: 72, height: 72)
                                .background(Circle().fill(chosenColor.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        Text(showingIconGrid ? "Choose an icon" : "Tap to change icon")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section { TextField("Name", text: $name) }

                Section("Color") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
                        colorSwatch(hex: nil)  // Auto (deterministic palette)
                        ForEach(categoryColorChoices, id: \.self) { colorSwatch(hex: $0) }
                    }
                    .padding(.vertical, 4)

                    // Full system color panel: wheel/spectrum + RGB sliders + hex and opacity fields.
                    ColorPicker(selection: customColorBinding, supportsOpacity: true) {
                        Label("Custom color", systemImage: "paintpalette")
                    }
                }

                if showingIconGrid {
                    Section("Icon") {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search icons (food, car, home…)", text: $iconQuery)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            if !iconQuery.isEmpty {
                                Button { iconQuery = "" } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        if iconResults.isEmpty {
                            Text("No icons match “\(iconQuery)”").font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 10)], spacing: 10) {
                                ForEach(iconResults) { choice in
                                    Button { icon = choice.symbol } label: {
                                        Image(systemName: choice.symbol)
                                            .font(.title3)
                                            .frame(width: 46, height: 46)
                                            .background(icon == choice.symbol ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground),
                                                        in: RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(icon == choice.symbol ? Color.accentColor : .clear, lineWidth: 2))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !dependents.isEmpty {
                    Section {
                        ForEach(dependents) { MappingReassignRow(dependent: $0, currentCanonical: editing?.name ?? "") }
                    } header: {
                        Text("Mapped here (\(dependents.count))")
                    } footer: {
                        Text("Bank and Splitwise categories that currently resolve to “\(editing?.name ?? "")”. Tap to reassign.")
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Category" : "Edit Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .errorAlert($errorText)
        }
    }

    /// A tappable color swatch; `hex == nil` is the "Auto" (deterministic palette) option.
    @ViewBuilder
    private func colorSwatch(hex: String?) -> some View {
        let isSelected = color == hex
        Button { color = hex } label: {
            Circle()
                .fill(hex.flatMap { Color(hex: $0) } ?? categoryPaletteColor(name))
                .frame(width: 34, height: 34)
                .overlay {
                    if hex == nil {
                        Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(.white)
                    }
                }
                .overlay(Circle().strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2)
                    .frame(width: 42, height: 42))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }

    private func save() {
        saving = true
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let chosenIcon = icon
        let chosenColor = color
        let editing = editing
        Task {
            defer { saving = false }
            do {
                if let editing {
                    try await env.categories(context).update(id: editing.id, name: trimmed, icon: chosenIcon,
                                                             color: .some(chosenColor))
                } else {
                    try await env.categories(context).create(name: trimmed, icon: chosenIcon, color: chosenColor)
                }
                dismiss()
            } catch { errorText = errorMessage(error) }
        }
    }
}
