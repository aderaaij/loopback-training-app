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

    enum FormStatus: Equatable {
        case idle
        case working
        case failed(String)
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
            }
            .listRowBackground(LB.surface)

            Section("Sign in") {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $password)
                    .textContentType(.password)

                Button { logIn() } label: { actionLabel("Sign In") }
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
        .onChange(of: serverScheme) { _, _ in resetStatus() }
        .onChange(of: serverHost) { _, _ in resetStatus() }
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

    private func logIn() {
        status = .working
        let device = UIDevice.current.name
        Task { @MainActor in
            do {
                try await session.login(
                    serverURL: trimmedURL,
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
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

    /// Maps errors to the copy the handoff doc specifies (§2).
    private func message(for error: Error) -> String {
        if let apiError = error as? WorkoutAPIError {
            switch apiError {
            case .invalidCredentials: return "Incorrect username or password."
            case .rateLimited: return "Too many attempts. Wait a minute and try again."
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
