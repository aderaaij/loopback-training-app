//
//  OnboardingView.swift
//  OpenHealthSync
//
//  First-run onboarding: a skippable flow that seeds the coach LLM's memory.
//  After login a new athlete answers goal / 30-min check / injuries /
//  availability, preceded by the HealthKit permission ask. Each answer becomes
//  a plan note (conversationId "ios-onboarding") via the training API.
//  Skipping everything leaves the app fully functional and writes nothing.
//

import SwiftUI
import UIKit

// MARK: - Answer models

enum RunGoal: String, CaseIterable, Identifiable {
    case first5k = "first_5k"
    case fiveK = "5k"
    case tenK = "10k"
    case halfMarathon = "half_marathon"
    case marathon = "marathon"
    case generalFitness = "general_fitness"

    var id: String { rawValue }
    var playbookValue: String { rawValue }

    /// Card label shown in the goal picker.
    var label: String {
        switch self {
        case .first5k:         return "My first 5K"
        case .fiveK:           return "A faster 5K"
        case .tenK:            return "A 10K"
        case .halfMarathon:    return "A half marathon"
        case .marathon:        return "A marathon"
        case .generalFitness:  return "Just running regularly"
        }
    }

    /// Secondary line under the label.
    var sublabel: String? {
        switch self {
        case .first5k:        return "I'm new to running, or coming back from nothing"
        case .generalFitness: return "No race — just staying consistent"
        default:              return nil
        }
    }

    /// Human phrase used inside the coach-facing summary line.
    var displayName: String {
        switch self {
        case .first5k:         return "first 5K"
        case .fiveK:           return "faster 5K"
        case .tenK:            return "10K"
        case .halfMarathon:    return "half marathon"
        case .marathon:        return "marathon"
        case .generalFitness:  return "general fitness"
        }
    }

    /// Everything except general fitness is a race → can carry a target date.
    var isRace: Bool { self != .generalFitness }
}

enum ThirtyMinAnswer: String, CaseIterable, Identifiable {
    case yes, no, notSure
    var id: String { rawValue }
    var label: String {
        switch self {
        case .yes:     return "Yes, comfortably"
        case .no:      return "Not yet"
        case .notSure: return "Not sure"
        }
    }
}

enum Injury: String, CaseIterable, Identifiable {
    case shinSplints, kneeITB, plantarFasciitis, achilles, stressFracture, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shinSplints:      return "shin splints"
        case .kneeITB:          return "knee/ITB"
        case .plantarFasciitis: return "plantar fasciitis"
        case .achilles:         return "achilles"
        case .stressFracture:   return "stress fracture"
        case .other:            return "other"
        }
    }
}

enum TrainTime: String, CaseIterable, Identifiable {
    case morning, lunch, evening, noPref
    var id: String { rawValue }
    var label: String {
        switch self {
        case .morning: return "Morning"
        case .lunch:   return "Lunch"
        case .evening: return "Evening"
        case .noPref:  return "No preference"
        }
    }
    /// The "prefers …" clause for the availability note; nil for no preference.
    var prefersClause: String? {
        switch self {
        case .morning: return "prefers mornings"
        case .lunch:   return "prefers lunches"
        case .evening: return "prefers evenings"
        case .noPref:  return nil
        }
    }
}

// MARK: - Steps

enum OnboardingStep: Hashable {
    case welcome, goal, thirtyMin, injuries, availability, finishing
}

// MARK: - Model

@MainActor
@Observable
final class OnboardingModel {
    private let apiClient: WorkoutAPIClient
    private let healthMetricsSyncer: HealthMetricsSyncer

    // Step navigation
    var stepIndex: Int = 0

    // Answers
    var goal: RunGoal?
    var raceDateEnabled = false
    var raceDate = Date()
    var thirtyMin: ThirtyMinAnswer?
    var injuries: Set<Injury> = []
    var injuriesNone = false
    var injuryNote = ""
    var selectedDays: Set<Int> = []   // 1=Mon … 7=Sun
    var trainTime: TrainTime?

    // Silent DOB capture
    private var birthYear: Int?

    // Write state (final step)
    enum WriteState { case idle, writing, success, failed }
    var writeState: WriteState = .idle

    init(apiClient: WorkoutAPIClient, healthMetricsSyncer: HealthMetricsSyncer) {
        self.apiClient = apiClient
        self.healthMetricsSyncer = healthMetricsSyncer
    }

    // MARK: Step sequence (derived — 30-min check is dropped for first_5k)

    var steps: [OnboardingStep] {
        var s: [OnboardingStep] = [.welcome, .goal]
        if goal != .first5k { s.append(.thirtyMin) }
        s.append(contentsOf: [.injuries, .availability, .finishing])
        return s
    }

    var currentStep: OnboardingStep {
        let steps = self.steps
        return steps[min(stepIndex, steps.count - 1)]
    }

    /// Question steps only (for progress dots).
    var questionSteps: [OnboardingStep] {
        steps.filter { $0 != .welcome && $0 != .finishing }
    }

    var questionPosition: Int? {
        questionSteps.firstIndex(of: currentStep)
    }

    var canGoBack: Bool { stepIndex > 0 && currentStep != .finishing }

    func advance() {
        let last = steps.count - 1
        if stepIndex < last {
            stepIndex = min(stepIndex + 1, last)
        }
    }

    func goBack() {
        if stepIndex > 0 { stepIndex -= 1 }
    }

    // MARK: HealthKit (welcome step)

    /// Requests HealthKit access, captures DOB, and kicks off a background
    /// sync while the athlete keeps answering. Non-blocking beyond the auth
    /// sheet itself.
    func connectHealthKit() async {
        _ = await healthMetricsSyncer.requestAuthorization()
        // Characteristic perms can't be queried — just attempt the read.
        birthYear = await healthMetricsSyncer.dateOfBirthComponents()?.year
        Task.detached { [healthMetricsSyncer] in
            try? await healthMetricsSyncer.syncMetrics()
        }
    }

    // MARK: Injuries helpers

    func toggleInjury(_ injury: Injury) {
        injuriesNone = false
        if injuries.contains(injury) { injuries.remove(injury) }
        else { injuries.insert(injury) }
    }

    func selectNoInjuries() {
        injuries.removeAll()
        injuriesNone = true
    }

    // MARK: Availability helpers

    func toggleDay(_ day: Int) {
        if selectedDays.contains(day) { selectedDays.remove(day) }
        else { selectedDays.insert(day) }
    }

    // MARK: Note building (§6)

    private struct PendingNote {
        let kind: String
        let importance: Int
        let summary: String
        let body: String?
        /// True when an existing note is the same logical note (→ PATCH).
        let matches: (PlanNote) -> Bool
    }

    private static func ymd(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// Selected weekdays in the display order the user reads them in.
    func orderedSelectedDays(mondayFirst: Bool) -> [Int] {
        let order = mondayFirst ? [1, 2, 3, 4, 5, 6, 7] : [7, 1, 2, 3, 4, 5, 6]
        return order.filter { selectedDays.contains($0) }
    }

    private func buildNotes(mondayFirst: Bool) -> [PendingNote] {
        var notes: [PendingNote] = []

        // Goal
        if let goal {
            let summary: String
            let body: String
            if goal.isRace {
                if raceDateEnabled {
                    let d = Self.ymd(raceDate)
                    summary = "Goal: \(goal.displayName) on \(d) (set in app onboarding)"
                    body = "Playbook goal: \(goal.playbookValue). Target date \(d)."
                } else {
                    summary = "Goal: \(goal.displayName) — no target date yet (set in app onboarding)"
                    body = "Playbook goal: \(goal.playbookValue)."
                }
            } else {
                summary = "Goal: \(goal.displayName) — no race (set in app onboarding)"
                body = "Playbook goal: \(goal.playbookValue)."
            }
            notes.append(PendingNote(
                kind: "decision", importance: 3, summary: summary, body: body,
                matches: { $0.kind == "decision" && $0.summary.hasPrefix("Goal:") }
            ))
        }

        // 30-minute check (never present for first_5k)
        if goal != .first5k, let thirtyMin {
            let summary: String
            switch thirtyMin {
            case .no:      summary = "Says they cannot yet run 30 min continuously (app onboarding)"
            case .yes:     summary = "Says they can run 30 min continuously (app onboarding)"
            case .notSure: summary = "Unsure whether they can run 30 min continuously (app onboarding)"
            }
            notes.append(PendingNote(
                kind: "observation", importance: 2, summary: summary, body: nil,
                matches: { $0.kind == "observation" && ($0.summary.hasPrefix("Says") || $0.summary.hasPrefix("Unsure")) }
            ))
        }

        // Injuries (None / skipped → no note)
        let realInjuries = Injury.allCases.filter { injuries.contains($0) }
        if !realInjuries.isEmpty {
            let labels = realInjuries.map(\.label).joined(separator: ", ")
            let summary = "Injury history: \(labels)"
            let text = injuryNote.trimmingCharacters(in: .whitespacesAndNewlines)
            notes.append(PendingNote(
                kind: "constraint", importance: 3, summary: summary, body: text.isEmpty ? nil : text,
                matches: { $0.kind == "constraint" && $0.summary.hasPrefix("Injury history:") }
            ))
        }

        // Availability (no days → no note)
        let days = orderedSelectedDays(mondayFirst: mondayFirst)
        if !days.isEmpty {
            let dayStr = days.map(Self.weekdayAbbrev).joined(separator: "/")
            var summary = "Available to train \(dayStr)"
            if let clause = trainTime?.prefersClause { summary += ", \(clause)" }
            summary += " (app onboarding)"
            notes.append(PendingNote(
                kind: "preference", importance: 2, summary: summary, body: nil,
                matches: { $0.kind == "preference" && $0.summary.hasPrefix("Available to train") }
            ))
        }

        // Date of birth (silent)
        if let birthYear {
            let currentYear = Calendar.current.component(.year, from: Date())
            let age = currentYear - birthYear
            let summary = "Born \(birthYear) — \(age) at onboarding"
            notes.append(PendingNote(
                kind: "observation", importance: 2, summary: summary, body: nil,
                matches: { $0.kind == "observation" && $0.summary.hasPrefix("Born") }
            ))
        }

        // Server caps summaries at 280 chars — enforce client-side.
        return notes.map { note in
            guard note.summary.count > 280 else { return note }
            let capped = String(note.summary.prefix(280))
            return PendingNote(kind: note.kind, importance: note.importance,
                               summary: capped, body: note.body, matches: note.matches)
        }
    }

    static func weekdayAbbrev(_ d: Int) -> String {
        switch d {
        case 1: return "Mon"
        case 2: return "Tue"
        case 3: return "Wed"
        case 4: return "Thu"
        case 5: return "Fri"
        case 6: return "Sat"
        default: return "Sun"
        }
    }

    /// True when at least one goal note carries a goal (drives the §7 nudge).
    var seededGoal: Bool { goal != nil }

    // MARK: Seed (final step)

    /// Writes the notes, PATCHing any that already exist for a re-run.
    func seedNotes(mondayFirst: Bool) async {
        let pending = buildNotes(mondayFirst: mondayFirst)
        guard !pending.isEmpty else {
            writeState = .success
            return
        }

        writeState = .writing
        do {
            let existing = try await apiClient.fetchPlanNotes(conversationId: "ios-onboarding")
            for note in pending {
                if let match = existing.first(where: note.matches) {
                    try await apiClient.updatePlanNote(
                        id: match.id,
                        PlanNoteUpdate(summary: note.summary, body: note.body)
                    )
                } else {
                    try await apiClient.createPlanNote(PlanNoteCreate(
                        kind: note.kind,
                        summary: note.summary,
                        body: note.body,
                        importance: note.importance,
                        conversationId: "ios-onboarding"
                    ))
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            writeState = .success
        } catch {
            // A 401 is handled globally (→ login); everything else surfaces the
            // Retry / Skip UI so the user is never trapped.
            writeState = .failed
        }
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @State private var model: OnboardingModel
    let onFinished: () -> Void
    /// Whatever the gated `.task` HK block would have done — called on finish.
    let startHealthPipeline: () async -> Void

    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true
    @AppStorage("onboardingSeededGoal") private var onboardingSeededGoal: Bool = false

    init(
        apiClient: WorkoutAPIClient,
        healthMetricsSyncer: HealthMetricsSyncer,
        onFinished: @escaping () -> Void,
        startHealthPipeline: @escaping () async -> Void
    ) {
        _model = State(initialValue: OnboardingModel(
            apiClient: apiClient,
            healthMetricsSyncer: healthMetricsSyncer
        ))
        self.onFinished = onFinished
        self.startHealthPipeline = startHealthPipeline
    }

    var body: some View {
        ZStack {
            LB.bg.ignoresSafeArea()

            Group {
                switch model.currentStep {
                case .welcome:      welcomeStep
                case .goal:         goalStep
                case .thirtyMin:    thirtyMinStep
                case .injuries:     injuriesStep
                case .availability: availabilityStep
                case .finishing:    finishingStep
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .opacity
            ))
            .id(model.stepIndex)
        }
        .animation(.easeInOut(duration: 0.25), value: model.stepIndex)
    }

    // MARK: Shared chrome

    private var topBar: some View {
        HStack {
            if model.canGoBack {
                LBCircleButton(systemName: "chevron.left", size: 38) {
                    withAnimation { model.goBack() }
                }
            }
            Spacer()
            Button {
                withAnimation { model.advance() }
            } label: {
                Text("Skip")
                    .font(.lbBody(15, .medium))
                    .foregroundStyle(LB.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            let count = model.questionSteps.count
            let pos = model.questionPosition ?? 0
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == pos ? LB.accent : LB.textFaint)
                    .frame(width: i == pos ? 20 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.2), value: pos)
            }
        }
    }

    private func primaryButton(_ label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.lbBody(16, .semibold))
                .foregroundStyle(LB.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                        .fill(enabled ? LB.accent : LB.surfaceTile)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.lbDisplay(27, .semibold))
            .tracking(-0.4)
            .foregroundStyle(LB.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }

    // MARK: Step 0 — Welcome + HealthKit

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                Image(systemName: "infinity")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(LB.accent)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(LB.accentTint()))
                    .overlay(Circle().strokeBorder(LB.accent.opacity(0.35), lineWidth: 1))
                    .shadow(color: LB.accent.opacity(0.4), radius: 22)

                VStack(spacing: 10) {
                    Text("Loopback")
                        .font(.lbDisplay(34, .bold))
                        .foregroundStyle(LB.textPrimary)
                    Text("Your training history is your coach's memory.")
                        .font(.lbBody(16))
                        .foregroundStyle(LB.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            VStack(spacing: 14) {
                Text("Connect Apple Health so your coach can see your runs, sleep and recovery.")
                    .font(.lbBody(13))
                    .foregroundStyle(LB.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                // No skip here: the system sheet is the real decision point
                // (enable all, some, or nothing), and it only shows once per
                // install — so passing through it here prevents it ambushing
                // the athlete later when the health pipeline starts.
                primaryButton("Connect Apple Health") {
                    Task {
                        await model.connectHealthKit()
                        withAnimation { model.advance() }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: Step A — Goal

    private var goalStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    progressDots
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                    stepTitle("What are you working toward?")

                    VStack(spacing: 10) {
                        ForEach(RunGoal.allCases) { goal in
                            goalCard(goal)
                        }
                    }
                    .padding(.horizontal, 20)

                    if let goal = model.goal, goal.isRace {
                        raceDateSection
                            .padding(.horizontal, 20)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 20)
            }
            primaryButton("Continue", enabled: model.goal != nil) {
                withAnimation { model.advance() }
            }
        }
    }

    private func goalCard(_ goal: RunGoal) -> some View {
        let on = model.goal == goal
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { model.goal = goal }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(goal.label)
                        .font(.lbDisplay(16, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    if let sub = goal.sublabel {
                        Text(sub)
                            .font(.lbBody(13))
                            .foregroundStyle(LB.textSecondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(on ? LB.accent : LB.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbCard(fill: on ? LB.accentTint(0.10) : LB.surface,
                    border: on ? LB.accent.opacity(0.5) : LB.line)
        }
        .buttonStyle(.plain)
    }

    private var raceDateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $model.raceDateEnabled.animation()) {
                Text("Racing on a specific date?")
                    .font(.lbBody(15, .medium))
                    .foregroundStyle(LB.textPrimary)
            }
            .tint(LB.accent)

            if model.raceDateEnabled {
                DatePicker(
                    "",
                    selection: $model.raceDate,
                    in: Date()...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(LB.accent)
                .labelsHidden()
            }
        }
        .padding(16)
        .lbCard(fill: LB.surfaceAlt, radius: LB.rInner)
    }

    // MARK: Step B — 30-minute check

    private var thirtyMinStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    progressDots
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                    stepTitle("Can you currently run about 30 minutes without stopping?")

                    VStack(spacing: 10) {
                        ForEach(ThirtyMinAnswer.allCases) { answer in
                            selectRow(
                                label: answer.label,
                                on: model.thirtyMin == answer
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) { model.thirtyMin = answer }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 20)
            }
            primaryButton("Continue") {
                withAnimation { model.advance() }
            }
        }
    }

    private func selectRow(label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(label)
                    .font(.lbDisplay(16, .semibold))
                    .foregroundStyle(LB.textPrimary)
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(on ? LB.accent : LB.textMuted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lbCard(fill: on ? LB.accentTint(0.10) : LB.surface,
                    border: on ? LB.accent.opacity(0.5) : LB.line)
        }
        .buttonStyle(.plain)
    }

    // MARK: Step C — Injuries

    private var injuriesStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    progressDots
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                    stepTitle("Any injuries we should train around?")

                    FlowChips(
                        injuries: model.injuries,
                        noneSelected: model.injuriesNone,
                        onToggle: { model.toggleInjury($0) },
                        onNone: { withAnimation { model.selectNoInjuries() } }
                    )
                    .padding(.horizontal, 20)

                    if !model.injuries.isEmpty {
                        TextField(
                            "",
                            text: $model.injuryNote,
                            prompt: Text("When, which side, how it resolved (optional)")
                                .font(.lbBody(14))
                                .foregroundStyle(LB.textMuted),
                            axis: .vertical
                        )
                        .font(.lbBody(14))
                        .foregroundStyle(LB.textPrimary)
                        .lineLimit(2...5)
                        .padding(14)
                        .lbCard(fill: LB.surfaceAlt, radius: LB.rInner)
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 20)
            }
            primaryButton("Continue") {
                withAnimation { model.advance() }
            }
        }
    }

    // MARK: Step D — Availability

    private var availabilityStep: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    progressDots
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                    stepTitle("Which days can you usually train?")

                    weekdayPills
                        .padding(.horizontal, 20)

                    VStack(alignment: .leading, spacing: 10) {
                        LBSectionHeader(title: "Preferred time")
                        timePills
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 20)
            }
            primaryButton("Continue") {
                withAnimation { model.advance() }
            }
        }
    }

    private var orderedWeekdays: [Int] {
        weekStartsOnMonday ? [1, 2, 3, 4, 5, 6, 7] : [7, 1, 2, 3, 4, 5, 6]
    }

    private var weekdayPills: some View {
        HStack(spacing: 7) {
            ForEach(orderedWeekdays, id: \.self) { day in
                let on = model.selectedDays.contains(day)
                Text(OnboardingModel.weekdayAbbrev(day))
                    .font(.lbBody(13, .semibold))
                    .foregroundStyle(on ? LB.bg : LB.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? LB.accent : LB.surfaceTile)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) { model.toggleDay(day) }
                    }
            }
        }
    }

    private var timePills: some View {
        HStack(spacing: 8) {
            ForEach(TrainTime.allCases) { time in
                let on = model.trainTime == time
                Text(time.label)
                    .font(.lbBody(13, .medium))
                    .foregroundStyle(on ? LB.accent : LB.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(on ? LB.accentTint() : LB.surfaceTile)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(on ? LB.accent.opacity(0.5) : .clear, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.12)) {
                            model.trainTime = on ? nil : time
                        }
                    }
            }
        }
    }

    // MARK: Final step — seed + done

    private var finishingStep: some View {
        VStack(spacing: 0) {
            Spacer()

            switch model.writeState {
            case .idle, .writing:
                VStack(spacing: 18) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(LB.accent)
                    Text("Finishing up…")
                        .font(.lbDisplay(20, .semibold))
                        .foregroundStyle(LB.textPrimary)
                }

            case .success:
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(LB.green)
                        .shadow(color: LB.green.opacity(0.5), radius: 20)
                    Text("You're all set")
                        .font(.lbDisplay(26, .semibold))
                        .tracking(-0.4)
                        .foregroundStyle(LB.textPrimary)
                    if model.seededGoal {
                        Text("Tell your coach you're ready and they'll build your plan.")
                            .font(.lbBody(15))
                            .foregroundStyle(LB.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

            case .failed:
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(LB.amber)
                    Text("Couldn't save your answers")
                        .font(.lbDisplay(20, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    Text("Check your connection and try again, or skip for now.")
                        .font(.lbBody(14))
                        .foregroundStyle(LB.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }

            Spacer()

            finishingButtons
        }
        .onAppear {
            if model.writeState == .idle {
                Task { await model.seedNotes(mondayFirst: weekStartsOnMonday) }
            }
        }
    }

    @ViewBuilder
    private var finishingButtons: some View {
        switch model.writeState {
        case .success:
            primaryButton("Done") { finish() }
        case .failed:
            VStack(spacing: 12) {
                primaryButton("Retry") {
                    Task { await model.seedNotes(mondayFirst: weekStartsOnMonday) }
                }
                Button { finish() } label: {
                    Text("Skip for now")
                        .font(.lbBody(15, .medium))
                        .foregroundStyle(LB.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 18)
            }
        case .idle, .writing:
            Color.clear.frame(height: 1)
        }
    }

    private func finish() {
        onboardingSeededGoal = model.seededGoal
        Task { await startHealthPipeline() }
        onFinished()
    }
}

// MARK: - Injury chips (wrapping layout)

private struct FlowChips: View {
    let injuries: Set<Injury>
    let noneSelected: Bool
    let onToggle: (Injury) -> Void
    let onNone: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Injury.allCases) { injury in
                chip(text: injury.label, on: injuries.contains(injury)) {
                    withAnimation(.easeInOut(duration: 0.12)) { onToggle(injury) }
                }
            }
            chip(text: "None", on: noneSelected, action: onNone)
        }
    }

    private func chip(text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Text(text)
            .font(.lbBody(14, .medium))
            .foregroundStyle(on ? LB.accent : LB.textSecondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(on ? LB.accentTint() : LB.surfaceTile)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(on ? LB.accent.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}
