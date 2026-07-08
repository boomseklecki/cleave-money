import SwiftUI

/// A small dimmed chip showing where a category came from (You / AI / Auto), mirroring `PendingPill`'s
/// style. Shown next to the category on transaction/expense detail; hidden for an unremarkable raw value.
struct CategoryProvenanceBadge: View {
    let source: CategoryOrigin

    var body: some View {
        if source.isNotable {
            Label(source.badgeLabel, systemImage: source.badgeSymbol)
                .font(.caption2).fontWeight(.medium)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
                .foregroundStyle(.secondary)
        }
    }
}
