import SwiftUI
import AuthenticationServices

/// Sign-in / onboarding: pick a server, then sign in with Apple, Google, or Splitwise.
/// Splitwise works against the standard backend; Apple needs the app's Sign-in-with-Apple entitlement
/// and Google needs `GIDClientID` in the Info.plist (both surfaced as friendly errors until configured).
/// Presented from Settings for now - not yet a hard launch gate.
public struct AuthGateView: View {
    /// When true the view is the app's launch gate (no "Close", no dismiss-on-success - the gate flips
    /// via `AppEnvironment` state). Default false = presented as a sheet from Settings.
    let isLaunchGate: Bool

    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var accessToken = ""
    @State private var demoName = ""
    @State private var busy = false
    @State private var errorText: String?

    public init(isLaunchGate: Bool = false) { self.isLaunchGate = isLaunchGate }

    /// Whether to surface a provider button - only those the backend offers (or all, when unknown).
    private func offers(_ provider: String) -> Bool {
        env.authProviders.isEmpty || env.authProviders.contains(provider)
    }

    public var body: some View {
        NavigationStack {
            Form {
                if env.serverIsDemo {
                    Section {
                        TextField("Your name (optional)", text: $demoName)
                            .textContentType(.givenName)
                        Button {
                            run { try await env.auth(context).startDemo(displayName: demoName) }
                        } label: {
                            Label("Start Demo", systemImage: "play.circle.fill")
                        }
                        .disabled(busy)
                    } header: {
                        Text("Try the Demo")
                    } footer: {
                        Text("Explore Cleave with sample data — no account needed. Nothing real is "
                             + "linked, and your demo data is private to you.")
                    }
                }

                Section {
                    TextField("API base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Use This Server") {
                        env.setBaseURL(baseURL)
                        Task { await env.loadServerInfo() }  // re-probe so the hint/providers update
                    }
                } header: {
                    Text("Server")
                } footer: {
                    if env.serverReachable == false {
                        Label("Couldn't reach this server. Check the URL — on a device, "
                              + "use the backend's LAN IP or tunnel host, not localhost.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if !env.serverIsDemo {
                  Section {
                    if offers("apple") {
                        SignInWithAppleButton(.signIn,
                            onRequest: { $0.requestedScopes = [.fullName, .email] },
                            onCompletion: handleApple)
                            .signInWithAppleButtonStyle(.black)
                            .frame(height: 44)
                            .listRowInsets(EdgeInsets())
                    }
                    if offers("google") {
                        Button { run { try await env.auth(context).signInWithGoogle(invite: env.pendingInvite) } } label: {
                            Label("Continue with Google", systemImage: "g.circle.fill")
                        }
                    }
                    if offers("splitwise") {
                        Button { run { try await env.auth(context).signInWithSplitwise(invite: env.pendingInvite) } } label: {
                            Label("Continue with Splitwise", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                  } header: {
                    Text("Sign In")
                  } footer: {
                    if env.pendingInvite != nil {
                        Label("You have an invite — sign in to join this server.", systemImage: "ticket")
                            .foregroundStyle(.tint)
                    }
                  }
                  .disabled(busy)
                }

                // Operator/testing affordance - not for demo guests (they use Start Demo).
                if !env.serverIsDemo {
                  Section {
                    DisclosureGroup("Have an access token?") {
                        SecureField("Access token", text: $accessToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Use Token", action: useToken)
                            .disabled(busy || accessToken.isEmpty)
                    }
                  } footer: {
                    Text("For testing/demo: paste a bearer token to sign in directly (e.g. a backend "
                         + "API token that maps to a specific user).")
                  }
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isLaunchGate {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
            }
            .task { baseURL = env.baseURLString }
            .errorAlert($errorText)
        }
    }

    /// Applies a pasted bearer token directly (e.g. a backend API token mapping to a user), then loads
    /// `/me`. A bad token 401s and is cleared by `refreshCurrentUser`, so we surface an error if no user
    /// resolved rather than flipping the gate into a 401 loop.
    private func useToken() {
        busy = true
        Task {
            defer { busy = false }
            await env.applySession(
                token: accessToken.trimmingCharacters(in: .whitespacesAndNewlines), context: context)
            if env.currentUser == nil {
                env.signOut(context)
                errorText = "That token didn't sign you in. Check the token and the server URL."
                return
            }
            accessToken = ""
            if !isLaunchGate { dismiss() }
        }
    }

    /// Runs a capture+exchange that yields a session token, applies it, and dismisses.
    private func run(_ work: @escaping () async throws -> String) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let token = try await work()
                await env.applySession(token: token, context: context)
                env.setPendingInvite(nil)  // redeemed (or unused) - don't carry it to a later sign-in
                if !isLaunchGate { dismiss() }
            } catch {
                if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                errorText = errorMessage(error)
            }
        }
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                errorText = AuthError.invalidResponse.errorDescription
                return
            }
            let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                .compactMap { $0 }.joined(separator: " ")
            run { try await env.auth(context).exchangeApple(identityToken: identityToken,
                                                            fullName: name.isEmpty ? nil : name,
                                                            invite: env.pendingInvite) }
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorText = errorMessage(error)
        }
    }
}
