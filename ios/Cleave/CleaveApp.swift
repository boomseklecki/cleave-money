import SwiftUI
import SwiftData
import CleaveAPI

@main
struct CleaveApp: App {
    /// Shared SwiftData container caching the server's source-of-truth data.
    let modelContainer: ModelContainer = {
        do {
            return try CleaveStore.makeModelContainer()
        } catch {
            // Last resort: launch with an ephemeral cache rather than crashing. Data re-syncs from
            // the server (the store is only a cache).
            return try! CleaveStore.makeModelContainer(inMemory: true)
        }
    }()

    /// App-wide services (API client, repositories, token state), injected into the environment.
    @State private var environment = AppEnvironment()

    /// Bridges APNs registration callbacks into the app (see `PushAppDelegate`).
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
        .modelContainer(modelContainer)
    }
}
