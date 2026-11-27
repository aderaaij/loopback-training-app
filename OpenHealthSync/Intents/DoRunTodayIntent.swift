//
//  DoRunTodayIntent.swift
//  OpenHealthSync
//
//  "Do my next run today": the same move as "Do it today" on a run's row
//  (Views/DoItToday.swift), through the same manager call. Server first, then
//  the watch. Asked without naming a run, it takes the next one planned for a
//  later day and says which before moving it.
//

import AppIntents
import Foundation
import SwiftData

struct DoRunTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Do Run Today"
    static let description = IntentDescription(
        "Brings a run planned for a later day forward to today, on your watch and for your coach."
    )
    /// It changes the plan, so not from a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Run", description: "The run to bring forward. Leave empty for the next one.")
    var run: PlannedRunEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Do \(\.$run) today")
    }

    @Dependency private var session: SessionStore
    @Dependency private var scheduleManager: WorkoutScheduleManager

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
            guard named.canDoToday else { throw LoopbackIntentError.notLater(named.displayName) }
            workout = named
        } else {
            guard let next = upcoming.first(where: \.canDoToday) else {
                return .result(dialog: "There's no later run to bring forward.")
            }
            // Nobody named it, so say which one before it moves.
            try await requestConfirmation(
                dialog: "Bring \(next.displayName) forward from \(IntentPhrasing.dayName(next.scheduledDate)) to today?"
            )
            workout = next
        }

        guard let skipping = try await runsToSkip(on: Date(), for: workout, in: scheduleManager) else {
            return .result(dialog: "Left \(workout.displayName) where it was.")
        }

        let context = try feedbackContext()
        let stillOn: [MissedWorkoutInfo]
        do {
            stillOn = try await withTimeLimit(15) {
                try await scheduleManager.bringForwardToToday(workout, skipping: skipping, modelContext: context)
            }
        } catch {
            throw LoopbackIntentError.serverUnreachable
        }
        await scheduleManager.settleChangeFromAction(saving: context)

        guard stillOn.isEmpty else {
            return .result(dialog: "\(MissedWorkoutFeedbackSheet.partialMoveMessage(moved: workout, stillOn: stillOn))")
        }
        return .result(dialog: "\(workout.displayName) is on for today.")
    }
}
