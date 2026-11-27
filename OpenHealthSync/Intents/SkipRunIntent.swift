//
//  SkipRunIntent.swift
//  OpenHealthSync
//
//  "Skip my next run": the skip the "Change plans" sheet makes for a run
//  that isn't due yet, through the same manager call. It asks for the reason
//  when it wasn't given. Server first, then the run comes off the watch.
//

import AppIntents
import Foundation
import SwiftData

struct SkipRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip Run"
    static let description = IntentDescription(
        "Skips a planned run: it comes off your watch, and your coach sees why."
    )
    /// It changes the plan, so not from a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Run", description: "The run to skip. Leave empty for the next one.")
    var run: PlannedRunEntity?

    @Parameter(title: "Reason", requestValueDialog: "What's the reason?")
    var reason: MissedWorkoutReason

    @Parameter(title: "Note", description: "Goes with the reasons Other, Sick and Injured.")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Skip \(\.$run)") {
            \.$reason
            \.$note
        }
    }

    @Dependency private var session: SessionStore
    @Dependency private var scheduleManager: WorkoutScheduleManager
    @Dependency private var setbackStore: SetbackStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard session.isAuthenticated else { throw LoopbackIntentError.notSignedIn }
        try await scheduleManager.loadScheduleForAction()

        let upcoming = scheduleManager.upcomingWorkouts.compactMap { MissedWorkoutInfo($0) }
        let workout: MissedWorkoutInfo
        if let run {
            guard let named = upcoming.first(where: { $0.id == run.id }) else {
                throw LoopbackIntentError.runNotFound
            }
            workout = named
        } else {
            guard let next = upcoming.first else {
                return .result(dialog: "You have no runs planned.")
            }
            // Nobody named it, so say which one before it goes.
            try await requestConfirmation(
                dialog: "Skip \(next.displayName), planned \(IntentPhrasing.when(next.scheduledDate))?"
            )
            workout = next
        }

        let reasonNote = reason.note(from: note ?? "")
        let context = try feedbackContext()
        do {
            try await withTimeLimit(15) {
                try await scheduleManager.skipUpcoming(
                    workout, reason: reason, note: reasonNote, modelContext: context
                )
            }
        } catch {
            throw LoopbackIntentError.serverUnreachable
        }
        let setback = await noteSetback(
            for: reason, note: reasonNote, runDate: workout.scheduledDate, in: setbackStore
        )
        await scheduleManager.settleChangeFromAction(saving: context)

        let skipped = "Skipped \(workout.displayName)."
        return .result(dialog: "\([skipped, setback].compactMap { $0 }.joined(separator: " "))")
    }
}
