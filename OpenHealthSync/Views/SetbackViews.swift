//
//  SetbackViews.swift
//  OpenHealthSync
//
//  Illness and injury tracking: the card on the Training tab while a setback
//  is open, the list of setbacks (Settings → Illness & injury), and the
//  log/edit form.
//

import SwiftUI

// MARK: - Training tab card

/// One card per open setback: how long it has been going on, a one-tap
/// "how are you today", and the way to mark it over.
struct SetbackBanner: View {
    @Environment(SetbackStore.self) private var store

    var body: some View {
        ForEach(store.active) { setback in
            SetbackCard(setback: setback)
        }
    }
}

private struct SetbackCard: View {
    let setback: Setback

    @Environment(SetbackStore.self) private var store
    @State private var showingRecovered = false
    @State private var showingEdit = false
    @State private var isSaving = false
    @State private var failed = false

    private var todaysStatus: SetbackStatus? {
        setback.checkin(on: .today)?.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LB.Space.md) {
            Button {
                showingEdit = true
            } label: {
                HStack(alignment: .top, spacing: LB.Space.md) {
                    Image(systemName: setback.kind.systemImage)
                        .font(.system(size: 22))
                        .foregroundStyle(LB.red)
                        .frame(width: 26)

                    VStack(alignment: .leading, spacing: LB.Space.xs) {
                        Text(headline)
                            .font(.lbDisplay(.subheadline, .semibold))
                            .foregroundStyle(LB.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(detail.uppercased())
                            .font(.lbMono(.caption))
                            .foregroundStyle(LB.textTertiary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(LB.textMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit details")

            if let recovery = setback.recovery, recovery.looksRecovered || recovery.isNotYet {
                recoveryNote(recovery)
            }

            VStack(alignment: .leading, spacing: LB.Space.sm) {
                Text("How are you today?")
                    .font(.lbBody(.secondary, .semibold))
                    .foregroundStyle(LB.textSecondary)

                HStack(spacing: LB.Space.sm) {
                    ForEach(SetbackStatus.allCases) { status in
                        statusChip(status)
                    }
                }

                if failed {
                    Text("Couldn't save. Check the connection to your server.")
                        .font(.lbBody(.secondary))
                        .foregroundStyle(LB.amber)
                }
            }

            Button {
                showingRecovered = true
            } label: {
                Text("I've recovered")
                    .font(.lbBody(.body, .semibold))
                    .foregroundStyle(suggestsRecovered ? LB.bg : LB.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, LB.Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                            .fill(suggestsRecovered ? LB.green : LB.optionOff)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                            .strokeBorder(suggestsRecovered ? Color.clear : LB.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(LB.Space.lg)
        .cardStyle(tint: LB.red)
        .disabled(isSaving)
        .sheet(isPresented: $showingRecovered) {
            SetbackRecoveredSheet(setback: setback)
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                SetbackFormView(setback: setback, isSheet: true)
            }
        }
    }

    private var suggestsRecovered: Bool {
        setback.recovery?.looksRecovered == true
    }

    /// What the recent data says: a green prompt when it looks over, a quiet
    /// line naming what is still off when it doesn't.
    private func recoveryNote(_ recovery: SetbackRecovery) -> some View {
        HStack(alignment: .top, spacing: LB.Space.sm) {
            Image(systemName: recovery.looksRecovered ? "checkmark.circle.fill" : "waveform.path.ecg")
                .font(.system(size: 15))
                .foregroundStyle(recovery.looksRecovered ? LB.green : LB.textTertiary)
                .padding(.top, LB.Space.xxs)

            VStack(alignment: .leading, spacing: LB.Space.xs) {
                if recovery.looksRecovered {
                    Text("You look recovered. Do you feel it?")
                        .font(.lbBody(.secondary, .semibold))
                        .foregroundStyle(LB.textPrimary)
                }
                Text(recovery.summary)
                    .font(.lbBody(.secondary))
                    .foregroundStyle(LB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(LB.Space.md)
        .background(
            RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                .fill(recovery.looksRecovered ? LB.green.opacity(0.12) : LB.optionOff)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                .strokeBorder(recovery.looksRecovered ? LB.green.opacity(0.30) : LB.line, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        let since = setback.start.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        if setback.kind == .injury, let part = setback.bodyPart, !part.isEmpty {
            return "\(part): injured since \(since)"
        }
        return "\(setback.kind.adjective) since \(since)"
    }

    private var detail: String {
        "Day \(setback.dayCount) · \(setback.severity.label)"
    }

    private func statusChip(_ status: SetbackStatus) -> some View {
        let isSelected = todaysStatus == status
        return Button {
            record(status)
        } label: {
            Text(status.label)
                .font(.lbBody(.secondary, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, LB.Space.md)
                .background(
                    RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                        .fill(isSelected ? LB.accentTint() : LB.optionOff)
                )
                .foregroundStyle(isSelected ? LB.accent : LB.textBright)
                .overlay {
                    RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                        .strokeBorder(isSelected ? LB.accent.opacity(0.45) : LB.line, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func record(_ status: SetbackStatus) {
        isSaving = true
        failed = false
        Task {
            do {
                try await store.checkIn(setback, status: status)
            } catch {
                failed = true
            }
            isSaving = false
        }
    }
}

// MARK: - Mark recovered

struct SetbackRecoveredSheet: View {
    let setback: Setback

    @Environment(SetbackStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var lastDay = Date()
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                LBSection {
                    DatePicker(
                        "Last day affected",
                        selection: $lastDay,
                        in: setback.start.date...max(setback.start.date, Date()),
                        displayedComponents: .date
                    )
                } footer: {
                    Text("The last day you felt it. Your coach builds your training back up from there.")
                }

                if let errorMessage {
                    LBSection {
                        Text(errorMessage)
                            .font(.lbBody(.body))
                            .foregroundStyle(LB.red)
                    }
                }
            }
            .lbList()
            .navigationTitle("Recovered")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(isSaving)
                }
            }
            .onAppear {
                // Recovered today usually means yesterday was the last bad day.
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                lastDay = max(setback.start.date, yesterday)
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(LB.bg)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await store.close(setback, lastDay: SetbackDay(lastDay))
                dismiss()
            } catch {
                errorMessage = "Couldn't save. Check the connection to your server and try again."
            }
            isSaving = false
        }
    }
}

// MARK: - List

struct SetbacksView: View {
    /// For the "update your server" explanation when the list can't load.
    let serverVersion: ServerVersion?

    @Environment(SetbackStore.self) private var store
    @State private var showingAdd = false

    /// The first server release with /api/setbacks.
    static let requiredServerVersion = ServerVersion(0, 1, 25)

    var body: some View {
        Form {
            switch store.loadState {
            case .idle, .loading:
                LBSection {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            case .failed:
                LBSection {
                    Text(failureMessage)
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.textSecondary)
                    Button("Try Again") {
                        Task { await store.load() }
                    }
                }
            case .loaded:
                loadedSections
            }
        }
        .lbList()
        .navigationTitle("Illness & Injury")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.loadState == .loaded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Log illness or injury", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingAdd) {
            NavigationStack {
                SetbackFormView(setback: nil, isSheet: true)
            }
        }
        .task { await store.load() }
    }

    @ViewBuilder
    private var loadedSections: some View {
        if store.setbacks.isEmpty {
            LBSection {
                Text("Log it when you're sick or injured. Your coach then knows without being told, holds back the hard sessions, and helps you build back up once you've recovered.")
                    .font(.lbBody(.body))
                    .foregroundStyle(LB.textSecondary)
                Button("Log Illness or Injury") { showingAdd = true }
            } footer: {
                sharingFooter
            }
        } else {
            if !store.active.isEmpty {
                LBSection {
                    ForEach(store.active) { setback in
                        NavigationLink {
                            SetbackFormView(setback: setback, isSheet: false)
                        } label: {
                            SetbackRow(setback: setback)
                        }
                    }
                } header: {
                    Text("Now")
                } footer: {
                    sharingFooter
                }
            }
            if !store.past.isEmpty {
                LBSection {
                    ForEach(store.past) { setback in
                        NavigationLink {
                            SetbackFormView(setback: setback, isSheet: false)
                        } label: {
                            SetbackRow(setback: setback)
                        }
                    }
                } header: {
                    Text("Earlier")
                } footer: {
                    if store.active.isEmpty { sharingFooter }
                }
            }
        }
    }

    @ViewBuilder
    private var sharingFooter: some View {
        if !DataConsent.current.contains(.recovery) {
            Text("Your coach only sees this while you share Recovery data. You can turn that on under Settings → Sync.")
        }
    }

    private var failureMessage: String {
        if let serverVersion, serverVersion < Self.requiredServerVersion {
            return "Illness and injury tracking needs Loopback server v\(Self.requiredServerVersion) or newer. This server is running v\(serverVersion)."
        }
        return "Couldn't load your log. Check the connection to your server."
    }
}

private struct SetbackRow: View {
    let setback: Setback

    var body: some View {
        HStack(spacing: LB.Space.md) {
            Image(systemName: setback.kind.systemImage)
                .foregroundStyle(setback.isActive ? LB.red : LB.textTertiary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: LB.Space.xs) {
                HStack(spacing: LB.Space.sm) {
                    Text(setback.title)
                        .font(.lbDisplay(.subheadline, .semibold))
                        .foregroundStyle(LB.textPrimary)
                        .lineLimit(1)
                    if setback.isActive {
                        LBStatusChip(text: "Ongoing", color: LB.red)
                    }
                }
                Text(dates)
                    .font(.lbMono(.caption))
                    .foregroundStyle(LB.textTertiary)
            }
        }
        .padding(.vertical, LB.Space.xs)
    }

    private var dates: String {
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        let days = setback.dayCount == 1 ? "1 day" : "\(setback.dayCount) days"
        guard let end = setback.end else {
            return "Since \(setback.start.date.formatted(style)) · \(days)"
        }
        if end == setback.start {
            return "\(end.date.formatted(style)) · \(days)"
        }
        let from = setback.start.date.formatted(.dateTime.day().month(.abbreviated))
        return "\(from) – \(end.date.formatted(style)) · \(days)"
    }
}

// MARK: - Log / edit

struct SetbackFormView: View {
    /// Nil logs a new one.
    let setback: Setback?
    /// Presented in its own sheet (Cancel button) rather than pushed.
    let isSheet: Bool

    @Environment(SetbackStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var kind: SetbackKind = .illness
    @State private var severity: SetbackSeverity = .moderate
    @State private var startDate = Date()
    @State private var isOngoing = true
    @State private var endDate = Date()
    @State private var bodyPart = ""
    @State private var note = ""
    @State private var didPrefill = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Form {
            LBSection {
                Picker("Kind", selection: $kind) {
                    ForEach(SetbackKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                if kind == .injury {
                    TextField("Where? For example left calf", text: $bodyPart)
                }
            }

            LBSection {
                Picker("How bad", selection: $severity) {
                    ForEach(SetbackSeverity.allCases) { severity in
                        Text(severity.label).tag(severity)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("How bad")
            } footer: {
                Text(severity.explanation(for: kind))
            }

            LBSection {
                DatePicker("First day", selection: $startDate, in: ...Date(), displayedComponents: .date)
                Toggle("Still going on", isOn: $isOngoing)
                if !isOngoing {
                    DatePicker(
                        "Last day affected",
                        selection: $endDate,
                        in: startDate...max(startDate, Date()),
                        displayedComponents: .date
                    )
                }
            }

            LBSection {
                TextField(kind == .illness ? "Symptoms, anything worth knowing" : "What happened, what hurts", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Notes")
            }

            if let setback, !setback.checkins.isEmpty {
                LBSection("Day by day") {
                    ForEach(setback.checkins.reversed()) { checkin in
                        HStack {
                            Text(checkin.day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            Spacer()
                            Text(checkin.status?.label ?? checkin.statusText.capitalized)
                                .foregroundStyle(LB.textSecondary)
                        }
                        .font(.lbBody(.body))
                    }
                }
            }

            if setback != nil {
                LBSection {
                    Button("Delete", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                } footer: {
                    Text("Deleting removes it from your history and from what your coach sees. To end it, turn off \"Still going on\" instead.")
                }
            }

            if let errorMessage {
                LBSection {
                    Text(errorMessage)
                        .font(.lbBody(.body))
                        .foregroundStyle(LB.red)
                }
            }
        }
        .lbList()
        .navigationTitle(setback == nil ? "Log Illness or Injury" : setback?.kind.label ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isSaving)
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let setback { run { try await store.delete(setback) } }
            }
        } message: {
            Text("This can't be undone.")
        }
        .disabled(isSaving)
        .onAppear(perform: prefill)
        .onChange(of: startDate) { _, newStart in
            if endDate < newStart { endDate = newStart }
        }
    }

    private func prefill() {
        guard !didPrefill else { return }
        didPrefill = true
        guard let setback else { return }
        kind = setback.kind
        severity = setback.severity
        startDate = setback.start.date
        isOngoing = setback.isActive
        endDate = setback.end?.date ?? Date()
        bodyPart = setback.bodyPart ?? ""
        note = setback.note ?? ""
    }

    private var draft: SetbackDraft {
        let part = bodyPart.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = SetbackDay(startDate)
        return SetbackDraft(
            kind: kind,
            severity: severity,
            start: start,
            end: isOngoing ? nil : max(SetbackDay(endDate), start),
            bodyPart: kind == .injury && !part.isEmpty ? part : nil,
            note: text.isEmpty ? nil : text
        )
    }

    private func save() {
        let draft = draft
        if draft.end == nil,
           let other = store.openSetback(kind: draft.kind, bodyPart: draft.bodyPart),
           other.id != setback?.id {
            errorMessage = draft.kind == .illness
                ? "You already have an illness that's still going on. Mark that one recovered first, or edit it."
                : "You already have an injury there that's still going on. Mark that one recovered first, or edit it."
            return
        }
        run {
            if let setback {
                try await store.update(setback, with: draft)
            } else {
                try await store.add(draft)
            }
        }
    }

    /// Runs a change against the server and leaves the form when it lands.
    private func run(_ change: @escaping () async throws -> Void) {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await change()
                dismiss()
            } catch {
                errorMessage = "Couldn't save. Check the connection to your server and try again."
            }
            isSaving = false
        }
    }
}
