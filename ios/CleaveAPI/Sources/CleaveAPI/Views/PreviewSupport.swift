#if DEBUG
import SwiftData
import SwiftUI

/// Xcode-preview scaffolding. Most Cleave screens read an `AppEnvironment` from the SwiftUI environment and a
/// SwiftData `ModelContext` from a `ModelContainer`, so a bare `#Preview { SomeView() }` crashes. `.previewEnvironment()`
/// injects both - an offline `AppEnvironment` + an in-memory store - so the view renders in the canvas.
///
/// Network-backed loads (`.task { load() }`) just fail quietly offline, so data-driven screens show their
/// loading/empty state. Purely presentational views (that take their data as parameters - `DetailHeader`,
/// `ItemListRow`, rows, badges) don't need this at all: preview them with inline sample data.
@MainActor
enum PreviewSupport {
    /// One offline environment shared across previews (its network calls fail quietly; nothing is persisted).
    static let environment = AppEnvironment()

    /// A fresh in-memory SwiftData store. (In-memory container creation doesn't hit disk, so `try!` is safe here.)
    static func container() -> ModelContainer {
        try! CleaveStore.makeModelContainer(inMemory: true)
    }
}

extension View {
    /// Inject the preview `AppEnvironment` + an in-memory SwiftData store so an environment/`@Query`-backed view
    /// renders in the Xcode canvas. Usage: `#Preview { NavigationStack { SomeView() }.previewEnvironment() }`.
    @MainActor func previewEnvironment() -> some View {
        environment(PreviewSupport.environment)
            .modelContainer(PreviewSupport.container())
    }
}
#endif
