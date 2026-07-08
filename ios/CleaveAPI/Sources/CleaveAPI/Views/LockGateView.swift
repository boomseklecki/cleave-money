import SwiftUI

/// Wraps the app in an optional local lock. When enabled (Settings), an opaque lock screen covers the
/// app on launch and whenever it returns from the background, until the device owner authenticates with
/// Face ID / passcode. Purely a privacy gate over the saved session - never affects sign-in.
struct LockGateView<Content: View>: View {
    @AppStorage(AppLock.enabledKey) private var lockEnabled = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var unlocked = false
    @State private var authenticating = false
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            content
            if lockEnabled && !unlocked {
                LockScreen(authenticating: authenticating) { Task { await unlock() } }
            }
        }
        .task { if lockEnabled { await unlock() } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                unlocked = false  // re-lock once it leaves the foreground
            case .active where lockEnabled && !unlocked:
                Task { await unlock() }
            default:
                break
            }
        }
        .onChange(of: lockEnabled) { _, enabled in
            // Turning the lock on from Settings shouldn't lock the current session immediately; it takes
            // effect on the next launch/background return.
            if enabled { unlocked = true }
        }
    }

    private func unlock() async {
        guard !authenticating else { return }
        authenticating = true
        defer { authenticating = false }
        if await AppLock.authenticate() {
            withAnimation { unlocked = true }
        }
    }
}

/// The full-screen lock placeholder, with a manual retry for when the prompt is dismissed.
private struct LockScreen: View {
    let authenticating: Bool
    let onUnlock: () -> Void

    /// The brand teal from the app icon's gradient.
    private let teal = Color(hex: "14B8A6") ?? .teal

    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(colors: [teal.opacity(0.22), teal.opacity(0.06)],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 24) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 108, height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

                VStack(spacing: 6) {
                    Text("Cleave").font(.title2.weight(.bold))
                    Label("Locked", systemImage: "lock.fill")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Button(action: onUnlock) {
                    Label("Unlock", systemImage: "faceid")
                }
                .buttonStyle(.borderedProminent)
                .tint(teal)
                .disabled(authenticating)
            }
            .padding()
        }
        .ignoresSafeArea()
    }
}
