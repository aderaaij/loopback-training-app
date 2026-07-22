//
//  AdvancedSettingsView.swift
//  OpenHealthSync
//
//  Destructive maintenance actions plus debug-only tooling.
//

import SwiftUI
#if DEBUG
import PulseUI
#endif

struct AdvancedSettingsView: View {
    let onRemoveAllWorkouts: () async -> Void

    @State private var showRemoveAllConfirmation = false

    #if DEBUG
    @State private var seeder = DebugWorkoutSeeder()
    @State private var markSeededAsSynced = true
    @State private var showDeleteSeededConfirmation = false
    #endif

    var body: some View {
        Form {
            Section("Danger Zone") {
                Button("Remove All Scheduled Workouts", role: .destructive) {
                    showRemoveAllConfirmation = true
                }
                .confirmationDialog(
                    "Remove all scheduled workouts from Apple Watch?",
                    isPresented: $showRemoveAllConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Remove All", role: .destructive) {
                        Task { await onRemoveAllWorkouts() }
                    }
                }
            }

            #if DEBUG
            networkLogSection
            developerSection
            #endif
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    #if DEBUG
    // MARK: - Network Log (debug builds only)

    private var networkLogSection: some View {
        Section {
            NavigationLink("Network Log") {
                ConsoleView(mode: .network)
                    .closeButtonHidden()
            }
        } header: {
            Text("Network")
        } footer: {
            Text("Debug builds only. Every Training API request is recorded on-device by Pulse, with the Authorization header redacted.")
        }
    }

    // MARK: - Developer (debug builds only)

    private var developerSection: some View {
        Section {
            Toggle("Mark seeded runs as synced", isOn: $markSeededAsSynced)
                .tint(LB.green)

            Button {
                Task { await seeder.seed(markAsSynced: markSeededAsSynced) }
            } label: {
                if seeder.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(LB.accent)
                        Text("Working…")
                    }
                } else {
                    Text("Seed Sample Workouts")
                }
            }
            .disabled(seeder.isWorking)

            Button("Delete Seeded Data", role: .destructive) {
                showDeleteSeededConfirmation = true
            }
            .disabled(seeder.isWorking)
            .confirmationDialog(
                "Delete every workout and sample this app wrote to HealthKit?",
                isPresented: $showDeleteSeededConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await seeder.deleteSeeded() }
                }
            }

            if let message = seeder.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Debug builds only. Seeds ~6 months of fake runs and strength sessions into HealthKit. Leave \"mark as synced\" on unless this device is signed into a test account — otherwise background sync uploads the fake workouts to your server.")
        }
    }
    #endif
}
