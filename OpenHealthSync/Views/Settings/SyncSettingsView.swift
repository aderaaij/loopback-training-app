//
//  SyncSettingsView.swift
//  OpenHealthSync
//
//  What the athlete shares with their coach, per domain, plus the history
//  re-upload and the fallback server route.
//
//  Each domain row carries two independent things: the toggle is *intent*, and
//  the caption under it is *evidence* — whether that domain has actually
//  produced a sample. They're separate because iOS won't tell us whether read
//  access was granted (see DataDomains), so an empty domain can mean withheld
//  permission or simply nothing recorded. The row suggests looking, and never
//  asserts which one it is.
//

import SwiftUI

struct SyncSettingsView: View {
    var session: SessionStore
    let healthMetricsSyncer: HealthMetricsSyncer

    @AppStorage(DataConsent.appStorageKey) private var domainsRaw: Int = DataDomains.required.rawValue
    @AppStorage("trainingAPIAlternativeURL") private var alternativeURLText: String = ""

    private var domains: DataDomains { DataDomains(rawValue: domainsRaw).union(.required) }

    /// Newest sample per domain. Absent key = nothing found.
    @State private var lastSeen: [DataDomains: Date] = [:]
    /// Until the first probe returns, "no data" is indistinguishable from "not
    /// looked yet", and only the latter is worth staying quiet about.
    @State private var evidenceLoaded = false

    private enum BackfillState: Equatable {
        case idle
        case running
        /// `nutritionDays` is nil when the nutrition leg failed while sleep and
        /// metrics landed — reported rather than hidden, since the two halves
        /// succeed independently.
        case done(stored: Int, nutritionDays: Int?)
        case failed
    }

    @State private var backfillState: BackfillState = .idle

    private var sharesAnyHealthData: Bool {
        !domains.intersection([.recovery, .body, .activity, .nutrition]).isEmpty
    }

    var body: some View {
        Form {
            Section {
                ForEach(DataDomains.ordered, id: \.rawValue) { domain in
                    domainRow(domain)
                }
            } header: {
                Text("Shared with your coach")
            } footer: {
                Text("Your coach can only see — and only reason about — the data you share here. Turning something off stops it syncing and removes its tools from the coach; what's already on your server stays until you delete it there.")
            }

            if sharesAnyHealthData {
                historySection
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
        .task { await loadEvidence() }
        .onChange(of: alternativeURLText) { _, _ in
            // Push the new fallback route to the live clients immediately;
            // @AppStorage already persisted the text.
            Task { await session.applyAlternativeURL() }
        }
    }

    // MARK: - Domain rows

    @ViewBuilder
    private func domainRow(_ domain: DataDomains) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 13) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(domain.tint.opacity(0.16))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: domain.symbol)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(domain.tint)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(domain.title)
                        .font(.lbDisplay(15, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    Text(domain.subtitle)
                        .font(.lbBody(12))
                        .foregroundStyle(LB.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if domain.isRequired {
                    // No toggle: without workouts there is no training history,
                    // which is the whole app. Saying so is more honest than
                    // offering a switch that can't be flipped.
                    Text("Always")
                        .font(.lbMono(10.5))
                        .tracking(0.8)
                        .foregroundStyle(LB.textMuted)
                } else {
                    Toggle("", isOn: binding(for: domain))
                        .labelsHidden()
                        .tint(domain.tint)
                }
            }

            if let note = evidenceNote(for: domain) {
                Text(note.text)
                    .font(.lbBody(11.5))
                    .foregroundStyle(note.isWarning ? LB.amber : LB.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if note.isWarning {
                    Button("Open Apple Health") { openHealthApp() }
                        .font(.lbBody(11.5, .semibold))
                        .foregroundStyle(domain.tint)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func binding(for domain: DataDomains) -> Binding<Bool> {
        Binding(
            get: { domains.contains(domain) },
            set: { isOn in
                var next = domains
                if isOn { next.insert(domain) } else { next.remove(domain) }
                // The app root observes this key: it re-requests authorization
                // for anything newly shared, rebuilds the background observers,
                // and pushes the new set to the server.
                domainsRaw = next.union(.required).rawValue
                if isOn {
                    // A domain just switched on has no evidence yet by
                    // definition; re-probe once HealthKit has been asked.
                    Task { await loadEvidence() }
                }
            }
        )
    }

    private struct EvidenceNote {
        let text: String
        let isWarning: Bool
    }

    /// The evidence line, or nil when there's nothing useful to say — a domain
    /// that isn't shared, or one we haven't probed yet.
    private func evidenceNote(for domain: DataDomains) -> EvidenceNote? {
        guard domains.contains(domain), evidenceLoaded else { return nil }

        if let date = lastSeen[domain] {
            return EvidenceNote(
                text: "Last reading \(date.formatted(.relative(presentation: .named))).",
                isWarning: false
            )
        }

        // Deliberately hedged. HealthKit reports nothing for a withheld read
        // permission and nothing for a domain the athlete simply doesn't
        // record, and it will not tell us which this is.
        return EvidenceNote(
            text: "No readings found. If you expected some, check Loopback under Apple Health → Sharing → Apps.",
            isWarning: true
        )
    }

    private func loadEvidence() async {
        let found = await healthMetricsSyncer.lastSampleDates(for: domains)
        lastSeen = found
        evidenceLoaded = true
    }

    private func openHealthApp() {
        // iOS offers no deep link into one app's health permissions, so this
        // lands on the Health app and the caption above says where to go.
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            Button {
                runBackfill()
            } label: {
                HStack {
                    Text(backfillState == .running ? "Uploading health history…" : "Re-upload health history")
                    Spacer()
                    if backfillState == .running {
                        ProgressView()
                    }
                }
            }
            .disabled(backfillState == .running)

            switch backfillState {
            case .done(let stored, let nutritionDays):
                Text(stored > 0
                     ? "Done — \(stored) new sleep sample\(stored == 1 ? "" : "s") stored and daily totals rebuilt."
                     : "Done — daily totals rebuilt; the server already had every sleep sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Only meaningful when nutrition is shared: with it off the
                // backfill skips that leg entirely, and nil means "not
                // attempted" rather than "failed".
                if domains.contains(.nutrition) {
                    if let nutritionDays {
                        Text(nutritionDays > 0
                             ? "Uploaded \(nutritionDays) day\(nutritionDays == 1 ? "" : "s") of logged food."
                             : "No food logged in Apple Health over that period — or Nutrition isn't shared with Loopback.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Nutrition couldn't be uploaded; everything else landed. Try again later.")
                            .font(.caption)
                            .foregroundStyle(LB.amber)
                    }
                }
            case .failed:
                Text("Upload failed. Check the server connection and try again.")
                    .font(.caption)
                    .foregroundStyle(LB.red)
            default:
                EmptyView()
            }
        } header: {
            Text("History")
        } footer: {
            Text("Re-reads the last 12 months of everything you share above and uploads it to your server, which rebuilds its records. Run this after switching a domain on to backfill its history. Safe to run repeatedly.")
        }
    }

    private func runBackfill() {
        backfillState = .running
        let domains = self.domains
        Task {
            do {
                let result = try await healthMetricsSyncer.backfillHealthHistory(domains: domains)
                backfillState = .done(
                    stored: result.sleepSamplesStored,
                    nutritionDays: result.nutritionDays
                )
                await loadEvidence()
            } catch {
                backfillState = .failed
            }
        }
    }
}
