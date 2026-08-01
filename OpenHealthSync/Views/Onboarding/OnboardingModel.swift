//
//  OnboardingModel.swift
//  OpenHealthSync
//
//  Answer vocabulary and state for first-run onboarding: the choice enums,
//  the step sequence, and OnboardingModel, which collects answers, turns them
//  into plan notes (conversationId "ios-onboarding"), and writes them to the
//  training API on the finishing step.
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
    case welcome, goal, dataSharing, thirtyMin, injuries, availability, finishing
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

    /// What the athlete is willing to share. Preselected generously — the coach
    /// is materially better with recovery and fuelling context — but nothing is
    /// persisted until they act on the data-sharing step.
    var sharedDomains: DataDomains = .all

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
        // Data sharing follows the goal on purpose: "what should your coach be
        // able to see?" is a question an athlete can only answer once they've
        // said what they want a coach for.
        var s: [OnboardingStep] = [.welcome, .goal, .dataSharing]
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

    // MARK: HealthKit (data-sharing step)

    /// Records the athlete's choice, then asks HealthKit for exactly those
    /// domains, captures DOB, and kicks off a background sync while they keep
    /// answering. Non-blocking beyond the auth sheet itself.
    ///
    /// Intent is stored *before* the sheet on purpose: it's our own state, and
    /// it stands whatever the athlete does in the system prompt. iOS never
    /// reports what they chose there — see `DataDomains`.
    func connectHealthKit() async {
        DataConsent.set(sharedDomains)
        await healthMetricsSyncer.requestAuthorization(for: sharedDomains)
        // Characteristic perms can't be queried — just attempt the read.
        birthYear = await healthMetricsSyncer.dateOfBirthComponents()?.year
        Task.detached { [healthMetricsSyncer] in
            try? await healthMetricsSyncer.syncMetrics()
        }
    }

    /// "Not now": training only, which is still a full running coach — plans,
    /// scheduling, completed runs, feedback. Settings can widen it later, and
    /// the history backfill there fills in whatever a domain missed.
    func declineHealthSharing() async {
        sharedDomains = .required
        DataConsent.set(.required)
        await healthMetricsSyncer.requestAuthorization(for: .required)
        birthYear = await healthMetricsSyncer.dateOfBirthComponents()?.year
    }

    func toggleDomain(_ domain: DataDomains) {
        guard !domain.isRequired else { return }
        if sharedDomains.contains(domain) {
            sharedDomains.remove(domain)
        } else {
            sharedDomains.insert(domain)
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
