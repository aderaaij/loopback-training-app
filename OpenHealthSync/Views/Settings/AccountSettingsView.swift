//
//  AccountSettingsView.swift
//  OpenHealthSync
//
//  Who's signed in, server health, token replacement, and sign out.
//

import SwiftUI

struct AccountSettingsView: View {
    var session: SessionStore
    let onReconnect: (_ baseURL: String, _ apiKey: String) async throws -> Void
    let onSignOut: () -> Void

    @State private var trainingScheme: ServerScheme = .http
    @State private var trainingHost = ""
    @State private var trainingAPIKey = ""
    @State private var apiKeyVisible = false
    @State private var status: ConnectionStatus = .idle

    @AppStorage("trainingAPIBaseURL") private var storedBaseURL: String = ""
    @AppStorage("trainingAPIKey") private var storedAPIKey: String = ""

    private enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    var body: some View {
        Form {
            Section("Account") {
                HStack {
                    Text("Signed in as")
                    Spacer()
                    Text(session.accountLabel)
                        .foregroundStyle(.secondary)
                }
                ServerStatusRow()
                if !session.serverURL.isEmpty {
                    HStack {
                        Text("Server")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(session.serverURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let version = session.serverVersion {
                    HStack {
                        Text("Version")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("v\(version.description)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = session.serverCompatibility.message {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(session.serverCompatibility.isSevere ? LB.amber : .secondary)
                }
            }

            Section {
                trainingAPIFields

                Button { save() } label: { saveButtonLabel("Save & Reconnect") }
                    .disabled(saveDisabled)

                connectionStatusRow
            } header: {
                Text("Replace Token")
            } footer: {
                Text("Paste a new token to switch credentials without signing out.")
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    onSignOut()
                }
            } footer: {
                Text("Signs out this device and returns to the login screen.")
            }
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !storedBaseURL.isEmpty {
                (trainingScheme, trainingHost) = ServerScheme.split(storedBaseURL)
            }
            trainingAPIKey = storedAPIKey
        }
        .task { await session.refreshServerHealth() }
        .onChange(of: trainingScheme) { _, _ in resetStatus() }
        .onChange(of: trainingHost) { _, _ in resetStatus() }
        .onChange(of: trainingAPIKey) { _, _ in resetStatus() }
    }

    // MARK: - Credentials form

    private var trainingAPIFields: some View {
        Group {
            ServerURLInput(scheme: $trainingScheme, host: $trainingHost)

            HStack {
                if apiKeyVisible {
                    TextField("API Token", text: $trainingAPIKey)
                        .textContentType(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    SecureField("API Token", text: $trainingAPIKey)
                        .textContentType(.none)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button {
                    apiKeyVisible.toggle()
                } label: {
                    Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var saveDisabled: Bool {
        ServerScheme.compose(trainingScheme, trainingHost).isEmpty
            || trainingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status == .connecting
    }

    private func save() {
        let url = ServerScheme.compose(trainingScheme, trainingHost)
        let key = trainingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .connecting
        Task { @MainActor in
            do {
                try await onReconnect(url, key)
                status = .connected
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func resetStatus() {
        if status != .connecting { status = .idle }
    }

    @ViewBuilder
    private func saveButtonLabel(_ title: String) -> some View {
        HStack(spacing: 8) {
            if status == .connecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(LB.accent)
            }
            Text(status == .connecting ? "Connecting…" : title)
        }
    }

    @ViewBuilder
    private var connectionStatusRow: some View {
        switch status {
        case .idle, .connecting:
            EmptyView()
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(LB.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
