//
//  PlanChangeReason.swift
//  OpenHealthSync
//
//  The reasons for moving or skipping a run, as Siri and Shortcuts offer
//  them: the same list the "Change plans" sheet shows, in the same words.
//  The coach reads them for patterns, so an action asks rather than guess.
//

import AppIntents

extension MissedWorkoutReason: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Reason")

    static let caseDisplayRepresentations: [MissedWorkoutReason: DisplayRepresentation] = [
        .busy: "Too busy",
        .tired: "Tired / low energy",
        .weather: "Weather",
        .soreness: "Sore / minor pain",
        .sick: "Sick",
        .injured: "Injured",
        .motivation: "Not feeling it",
        .other: "Other",
    ]
}

extension AppIntent {
    /// A run moved or skipped for sickness or injury puts the setback itself
    /// on record, as it does from the sheet. Returns the sentence that says
    /// so, or nil when there is nothing to say. Best effort: the check-in
    /// already carries the reason.
    @MainActor
    func noteSetback(
        for reason: MissedWorkoutReason,
        note: String?,
        runDate: Date,
        in setbackStore: SetbackStore
    ) async -> String? {
        guard let kind = reason.setbackKind else { return nil }
        _ = try? await withTimeLimit(8) {
            await setbackStore.noteSetback(kind: kind, on: runDate, note: note)
        }
        let day = min(SetbackDay(runDate), .today)
        guard setbackStore.setback(kind: kind, covering: day) != nil else { return nil }
        return "Your \(kind.label.lowercased()) is on record for your coach."
    }
}
