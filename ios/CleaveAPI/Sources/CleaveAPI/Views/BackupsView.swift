import SwiftUI

/// Admin-only backup manager: create, browse, restore, and delete full-stack backups (database + receipts).
/// Backups are server-only (no SwiftData), so this view drives everything from `@State` + the backups
/// repository. Create/restore are long-running - a progress row shows while one is in flight.
struct BackupsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var backups: [Components.Schemas.BackupResponse] = []
    @State private var loaded = false
    @State private var working: String?     // status text while a create/restore/delete runs
    @State private var errorText: String?
    @State private var newLabel = ""
    @State private var showingCreate = false
    @State private var confirmingRestore: Components.Schemas.BackupResponse?
    @State private var confirmingDelete: Components.Schemas.BackupResponse?

    var body: some View {
        List {
            if let working {
                Section {
                    HStack(spacing: 10) { ProgressView(); Text(working).foregroundStyle(.secondary) }
                }
            }
            if backups.isEmpty && loaded && working == nil {
                ContentUnavailableView("No Backups", systemImage: "externaldrive",
                    description: Text("Create a backup to snapshot the database and all receipts."))
            }
            ForEach(backups, id: \.name) { backup in
                row(backup)
                    .swipeActions(allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { confirmingDelete = backup }
                        Button("Restore") { confirmingRestore = backup }.tint(.orange)
                    }
            }
        }
        .navigationTitle("Local Backups")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
                    .disabled(working != nil)
            }
        }
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .alert("New Backup", isPresented: $showingCreate) {
            TextField("Label (optional)", text: $newLabel)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { newLabel = "" }
        } message: {
            Text("Snapshots the database and all receipts into one archive. This can take a while.")
        }
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(get: { confirmingRestore != nil },
                                 set: { if !$0 { confirmingRestore = nil } }),
            titleVisibility: .visible, presenting: confirmingRestore
        ) { backup in
            Button("Restore", role: .destructive) { restore(backup) }
        } message: { _ in
            Text("Replaces ALL current data on this backend with this backup. A safety backup is taken first.")
        }
        .confirmationDialog(
            "Delete this backup?",
            isPresented: Binding(get: { confirmingDelete != nil },
                                 set: { if !$0 { confirmingDelete = nil } }),
            titleVisibility: .visible, presenting: confirmingDelete
        ) { backup in
            Button("Delete", role: .destructive) { delete(backup) }
        }
        .errorAlert($errorText)
    }

    private func row(_ b: Components.Schemas.BackupResponse) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(b.label ?? "\(b.kind.capitalized) backup").fontWeight(.medium)
                Spacer()
                kindBadge(b.kind)
            }
            Text("\(b.created_at.formatted(date: .abbreviated, time: .shortened)) · \(sizeText(b.size_bytes))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func kindBadge(_ kind: String) -> some View {
        let scheduled = kind == "scheduled"
        return Text(kind.capitalized)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((scheduled ? Color.blue : Color.gray).opacity(0.15),
                        in: Capsule())
            .foregroundStyle(scheduled ? .blue : .secondary)
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func load() async {
        do {
            backups = try await env.backups.list()
            loaded = true
        } catch {
            if let message = errorMessage(error) { errorText = message }
        }
    }

    private func create() {
        let label = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        newLabel = ""
        Task {
            working = "Creating backup…"
            defer { working = nil }
            do {
                _ = try await env.backups.create(label: label.isEmpty ? nil : label)
                await load()
            } catch { errorText = errorMessage(error) }
        }
    }

    private func restore(_ backup: Components.Schemas.BackupResponse) {
        Task {
            working = "Restoring… do not close the app"
            defer { working = nil }
            do {
                _ = try await env.backups.restore(name: backup.name)
                await load()
            } catch { errorText = errorMessage(error) }
        }
    }

    private func delete(_ backup: Components.Schemas.BackupResponse) {
        Task {
            working = "Deleting…"
            defer { working = nil }
            do {
                try await env.backups.delete(name: backup.name)
                await load()
            } catch { errorText = errorMessage(error) }
        }
    }
}
