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
    let healthMetricsSyncer: HealthMetricsSyncer
    let onReconnect: (_ baseURL: String, _ apiKey: String) async throws -> Void
    let onSignOut: () -> Void
    let onRemoveAllWorkouts: () async -> Void

    @AppStorage(DataConsent.appStorageKey) private var domainsRaw: Int = DataDomains.required.rawValue

    private var sharesNutrition: Bool {
        DataDomains(rawValue: domainsRaw).contains(.nutrition)
    }

    var body: some View {
        NavigationStack {
            Form {
                LBSection("Preferences") {
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
                        SyncSettingsView(session: session, healthMetricsSyncer: healthMetricsSyncer)
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
                        ShoesView(serverVersion: session.serverVersion)
                    } label: {
                        PreferenceRow(
                            systemImage: "shoe.2.fill",
                            tint: LB.amber,
                            title: "Shoes",
                            subtitle: "Mileage & default pair"
                        )
                    }

                    // Fuelling is read by the coach under Nutrition, so it
                    // is offered to those who share that.
                    if sharesNutrition {
                        NavigationLink {
                            FuelProductsView(serverVersion: session.serverVersion)
                        } label: {
                            PreferenceRow(
                                systemImage: "waterbottle.fill",
                                tint: LB.green,
                                title: "Fuelling",
                                subtitle: "Drinks & gels for your runs"
                            )
                        }
                    }

                    NavigationLink {
                        SetbacksView(serverVersion: session.serverVersion)
                    } label: {
                        PreferenceRow(
                            systemImage: "cross.case.fill",
                            tint: LB.red,
                            title: "Illness & Injury",
                            subtitle: "Log it and track your recovery"
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

                LBSection(bare: true) {
                    brandFooter
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
            }
            .lbList()
            .lbNavigationBarMargins()
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
        VStack(spacing: LB.Space.md) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96)
            Text("Loopback")
                .font(.lbDisplay(.headline, .semibold))
                .tracking(-0.4)
                .foregroundStyle(LB.textPrimary)
            Text("SELF-HOSTED TRAINING · v1.0")
                .font(.lbMono(.caption))
                .tracking(1)
                .foregroundStyle(LB.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LB.Space.xxl)
    }
}
