//
//  SyncSettingsView.swift
//  OpenHealthSync
//
//  Health-metrics sync toggle and the fallback server route.
//

import SwiftUI

struct SyncSettingsView: View {
    var session: SessionStore

    @AppStorage("healthMetricsSyncEnabled") private var healthMetricsSyncEnabled: Bool = true
    @AppStorage("trainingAPIAlternativeURL") private var alternativeURLText: String = ""

    var body: some View {
        Form {
            Section("Health Metrics") {
                Toggle("Sync health data to Training API", isOn: $healthMetricsSyncEnabled)
                    .tint(LB.green)

                if healthMetricsSyncEnabled {
                    Text("Sleep, heart rate, HRV, weight, VO2Max, steps, and more are synced daily to your training server for AI coaching context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                TextField("Fallback URL (optional)", text: $alternativeURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Fallback Server")
            } footer: {
                Text("Second route to the same server — e.g. its LAN address when the primary URL goes through Tailscale. When the primary can't be reached, requests retry here automatically. Include the scheme, like http://192.168.1.20:8000.")
            }
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: alternativeURLText) { _, _ in
            // Push the new fallback route to the live clients immediately;
            // @AppStorage already persisted the text.
            Task { await session.applyAlternativeURL() }
        }
    }
}
