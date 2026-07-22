//
//  SettingsSheet.swift
//  OpenHealthSync
//
//  Settings hub, presented as a sheet from the Training tab's gear button.
//  Hub-and-spoke: each row pushes a focused subpage.
//

import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var session: SessionStore
    let onReconnect: (_ baseURL: String, _ apiKey: String) async throws -> Void
    let onSignOut: () -> Void
    let onRemoveAllWorkouts: () async -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Preferences") {
                    NavigationLink {
                        AccountSettingsView(
                            session: session,
                            onReconnect: onReconnect,
                            onSignOut: onSignOut
                        )
                    } label: {
                        PreferenceRow(
                            systemImage: "person.crop.circle",
                            tint: LB.accent,
                            title: "Account",
                            subtitle: session.accountLabel
                        )
                    }

                    NavigationLink {
                        SyncSettingsView(session: session)
                    } label: {
                        PreferenceRow(
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: LB.blue,
                            title: "Sync",
                            subtitle: "Health metrics & fallback server"
                        )
                    }

                    NavigationLink {
                        TrainingSettingsView()
                    } label: {
                        PreferenceRow(
                            systemImage: "figure.run",
                            tint: LB.green,
                            title: "Training",
                            subtitle: "Run time & week start"
                        )
                    }

                    NavigationLink {
                        AdvancedSettingsView(onRemoveAllWorkouts: onRemoveAllWorkouts)
                    } label: {
                        PreferenceRow(
                            systemImage: "slider.horizontal.3",
                            tint: LB.violet,
                            title: "Advanced",
                            subtitle: "Danger zone & developer extras"
                        )
                    }
                }
                .listRowBackground(LB.surface)

                Section {
                    brandFooter
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            .lbList()
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .tint(LB.textPrimary)
                }
            }
        }
    }

    // MARK: - Brand Footer

    private var brandFooter: some View {
        VStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96)
            Text("Loopback")
                .font(.lbDisplay(22, .semibold))
                .tracking(-0.4)
                .foregroundStyle(LB.textPrimary)
            Text("SELF-HOSTED TRAINING · v1.0")
                .font(.lbMono(10.5))
                .tracking(1)
                .foregroundStyle(LB.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}
