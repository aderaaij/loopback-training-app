//
//  LoginView.swift
//  OpenHealthSync
//
//  Pre-auth screen. Primary path is username + password against the Training
//  API's /api/auth/login; an Advanced disclosure keeps the legacy "paste a
//  token" path for admins / self-hosters.
//

import SwiftUI
import UIKit

struct LoginView: View {
    var session: SessionStore

    /// Dev convenience only: prefill the maintainer's server in Debug builds.
    /// Release builds must not bake in a personal hostname.
    #if DEBUG
    private static let defaultServerURL = "https://ardencore.tail38e03e.ts.net:8443"
    #else
    private static let defaultServerURL = ""
    #endif

    // Self-hosted servers are typically plain HTTP on a LAN/tailnet, so http
    // is the friendlier default for a blank form; a stored URL overrides it.
    @State private var serverScheme: ServerScheme = .http
    @State private var serverHost = ""
    @State private var username = ""
    @State private var password = ""

    @State private var showAdvanced = false
    @State private var manualToken = ""
    @State private var manualTokenVisible = false

    @State private var status: FormStatus = .idle
    @State private var handshake: Handshake = .idle
    /// The address the last handshake actually reached: https when the server
    /// redirected an http:// address. Sign-in goes there, so the password is
    /// never posted to the plain-http side of that redirect.
    @State private var verifiedURL: String?

    enum FormStatus: Equatable {
        case idle
        case working
        case failed(String)
    }

    /// Result of the `/api/health` handshake, surfaced under the Server field.
    /// A `.warning` flips Sign In to "Sign In Anyway" — the version gate never
    /// hard-blocks (doc §2).
    enum Handshake: Equatable {
        case idle
        case verified(String)
        case warning(ServerCompatibility)
    }

    var body: some View {
        Form {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            Section("Server") {
                ServerURLInput(scheme: $serverScheme, host: $serverHost)
                handshakeRow
            }
            .listRowBackground(LB.surface)

            Section("Sign in") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)

                Button { logIn() } label: {
                    actionLabel(warningAcknowledged ? "Sign In Anyway" : "Sign In")
                }
                .disabled(loginDisabled)

                statusRow
            }
            .listRowBackground(LB.surface)

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Text("Paste a token instead of signing in. A token works exactly like a signed-in session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        if manualTokenVisible {
                            TextField("API Token", text: $manualToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("API Token", text: $manualToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button {
                            manualTokenVisible.toggle()
                        } label: {
                            Image(systemName: manualTokenVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button { applyToken() } label: { actionLabel("Save Token") }
                        .disabled(tokenDisabled)
                }
            }
            .listRowBackground(LB.surface)
        }
        .lbList()
        .navigationTitle("Sign In")
        .onAppear {
            if serverHost.isEmpty {
                let stored = session.serverURL.isEmpty ? Self.defaultServerURL : session.serverURL
                if !stored.isEmpty {
                    (serverScheme, serverHost) = ServerScheme.split(stored)
                }
            }
            if username.isEmpty { username = session.username }
        }
        .onChange(of: serverScheme) { _, _ in resetHandshake() }
        .onChange(of: serverHost) { _, _ in resetHandshake() }
        .onChange(of: username) { _, _ in resetStatus() }
        .onChange(of: password) { _, _ in resetStatus() }
        .onChange(of: manualToken) { _, _ in resetStatus() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 108)
            Text("Loopback")
                .font(.lbDisplay(22, .semibold))
                .tracking(-0.4)
                .foregroundStyle(LB.textPrimary)
            Text("Sign in to your training server to sync workouts, plans, and health metrics.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Actions

    private var trimmedURL: String { ServerScheme.compose(serverScheme, serverHost) }

    private var loginDisabled: Bool {
        trimmedURL.isEmpty
            || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || password.isEmpty
            || status == .working
    }

    private var tokenDisabled: Bool {
        trimmedURL.isEmpty
            || manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status == .working
    }

    /// Whether a compatibility warning is already on screen — the next Sign In
    /// tap is the explicit "anyway" and skips a repeat handshake.
    private var warningAcknowledged: Bool {
        if case .warning = handshake { return true }
        return false
    }

    private func logIn() {
        let url = trimmedURL
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = UIDevice.current.name
        let acknowledged = warningAcknowledged
        status = .working
        Task { @MainActor in
            do {
                // "Sign In Anyway" skips the handshake, so it reuses the
                // address the first one reached.
                var target = acknowledged ? (verifiedURL ?? url) : url
                // Handshake before the first sign-in attempt (doc §1–2). A
                // wrong-server / DB-down probe throws and is shown below; a
                // version warning pauses for an explicit "Sign In Anyway".
                if !acknowledged {
                    let (compat, reached) = try await session.probeServerHealth(serverURL: url)
                    target = reached.absoluteString
                    verifiedURL = target
                    if compat.isWarning {
                        handshake = .warning(compat)
                        status = .idle
                        return
                    }
                    handshake = session.serverVersion.map { .verified("Loopback server · v\($0)") } ?? .idle
                }
                try await session.login(
                    serverURL: target,
                    username: user,
                    password: password,
                    deviceName: device
                )
                // isAuthenticated flips → the app root swaps this view for the app.
            } catch {
                status = .failed(message(for: error))
            }
        }
    }

    private func applyToken() {
        status = .working
        let token = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                try await session.applyManualToken(serverURL: trimmedURL, token: token)
            } catch {
                status = .failed(message(for: error))
            }
        }
    }

    private func resetStatus() {
        if status != .working { status = .idle }
    }

    /// A changed server address invalidates the last handshake — re-verify on
    /// the next Sign In.
    private func resetHandshake() {
        handshake = .idle
        verifiedURL = nil
        resetStatus()
    }

    /// Maps errors to the copy the handoff doc specifies (§1–2).
    private func message(for error: Error) -> String {
        if let apiError = error as? WorkoutAPIError {
            switch apiError {
            case .invalidCredentials: return "Incorrect username or password."
            case .rateLimited: return "Too many attempts. Wait a minute and try again."
            case .notLoopbackServer: return "That address isn't a Loopback server."
            case .databaseUnavailable: return "Server reached, but its database is down. Try again shortly."
            case .serverError(let code) where code == 401 || code == 403:
                return "Incorrect username or password."
            default: break
            }
        }
        return "Couldn't reach the server. Check the address."
    }

    // MARK: - UI helpers

    @ViewBuilder
    private func actionLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            if status == .working {
                ProgressView()
                    .controlSize(.small)
                    .tint(LB.accent)
            }
            Text(status == .working ? "Connecting…" : title)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        if case .failed(let message) = status {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// Server-identity + version readout under the URL field: a green tick when
    /// the handshake succeeds, an amber/muted warning when the version is out
    /// of range (sign-in still available via "Sign In Anyway").
    @ViewBuilder
    private var handshakeRow: some View {
        switch handshake {
        case .idle:
            EmptyView()
        case .verified(let text):
            Label(text, systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(LB.green)
        case .warning(let compatibility):
            if let message = compatibility.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(compatibility.isSevere ? LB.amber : LB.textSecondary)
            }
        }
    }
}

#Preview {
    NavigationStack {
        LoginView(session: SessionStore(
            apiClient: WorkoutAPIClient(),
            workoutManager: WorkoutManager()
        ))
    }
    .preferredColorScheme(.dark)
}
