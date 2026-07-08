import SwiftUI

/// Drag to reorder the three main tabs. Settings is pinned last (shown but not movable). The order persists
/// locally and backs up to the per-owner preferences blob (restores on a new device). Reached from Settings.
struct CustomizeTabsView: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage("tabOrder") private var tabOrderRaw = MainTab.serialize(MainTab.allCases)

    var body: some View {
        List {
            Section {
                ForEach(MainTab.parse(tabOrderRaw)) { tab in
                    Label(tab.title, systemImage: tab.icon)
                }
                .onMove(perform: move)
            } footer: {
                Text("Drag to reorder your main tabs. Settings always stays last.")
            }

            Section {
                Label("Settings", systemImage: "gearshape.fill").foregroundStyle(.secondary)
            } footer: {
                Text("Always last.")
            }
        }
        .environment(\.editMode, .constant(.active))  // always show drag handles
        .navigationTitle("Customize Tabs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func move(_ offsets: IndexSet, _ destination: Int) {
        var order = MainTab.parse(tabOrderRaw)
        order.move(fromOffsets: offsets, toOffset: destination)
        tabOrderRaw = MainTab.serialize(order)  // local, instant (the TabView re-renders)
        Task { await env.setTabOrder(order) }   // persist + back up
    }
}
