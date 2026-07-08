import SwiftUI

/// Admin-only, read-only list of the off-device (restic) snapshots. Mirrors `BackupsView`'s row/list scaffold
/// but without create/restore/delete - offsite restore stays the documented DR runbook (OPERATIONS.md).
struct OffsiteSnapshotsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var snapshots: [Components.Schemas.OffsiteSnapshot] = []
    @State private var loaded = false
    @State private var errorText: String?

    var body: some View {
        List {
            if snapshots.isEmpty && loaded {
                ContentUnavailableView("No Off-device Snapshots", systemImage: "externaldrive.badge.icloud",
                                       description: Text("Snapshots appear here once off-device backup is enabled "
                                                         + "and a backup has run."))
            }
            ForEach(snapshots, id: \.id) { row($0) }
        }
        .navigationTitle("Off-device Snapshots")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .errorAlert($errorText)
    }

    private func row(_ s: Components.Schemas.OffsiteSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(s.tags?.first?.capitalized ?? "Snapshot").fontWeight(.medium)
                Spacer()
                Text(s.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Text(s.time.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            snapshots = try await env.backups.offsiteSnapshots()
            loaded = true
        } catch {
            if let message = errorMessage(error) { errorText = message }
        }
    }
}
