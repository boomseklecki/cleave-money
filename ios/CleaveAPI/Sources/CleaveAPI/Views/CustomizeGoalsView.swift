import SwiftUI

/// Drag to reorder the Goals page sections (Spending / Budgets / Savings Goals). The month selector stays at
/// the top and Trends at the bottom regardless. The order persists locally and backs up to the per-owner
/// preferences blob (restores on a new device). Presented as a sheet from the Goals filter menu.
struct CustomizeGoalsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @AppStorage("goalsOrder") private var goalsOrderRaw = GoalSection.serialize(GoalSection.allCases)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(GoalSection.parse(goalsOrderRaw)) { section in
                        Label(section.title, systemImage: section.icon)
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("Drag to reorder the Goals sections. The month selector stays on top and Trends stays "
                         + "at the bottom.")
                }
            }
            .environment(\.editMode, .constant(.active))  // always show drag handles
            .navigationTitle("Reorder Sections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var order = GoalSection.parse(goalsOrderRaw)
        order.move(fromOffsets: offsets, toOffset: destination)
        goalsOrderRaw = GoalSection.serialize(order)  // local, instant (the Goals page re-renders)
        Task { await env.setGoalsOrder(order) }       // persist + back up
    }
}
