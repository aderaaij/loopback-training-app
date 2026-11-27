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
                dialog: "Bring \(next.displayName) forward from \(Self.day(next.scheduledDate)) to today?"
            )
            workout = next
        }

        // Today may already have a run: skip it to make room, or keep both,
        // as the app asks.
        var skipping: [MissedWorkoutInfo] = []
        let inTheWay = scheduleManager.openSessions(on: Date(), otherThan: workout.id)
        if !inTheWay.isEmpty {
            let names = inTheWay.map(\.displayName).joined(separator: ", ")
            let skip = IntentChoiceOption(title: "Move & skip \(names)")
            let keep = IntentChoiceOption(title: "Keep both")
            let choice = try await requestChoice(
                between: [skip, keep, .cancel],
                dialog: "You already have \(names) today."
            )
            if choice == skip {
                skipping = inTheWay
            } else if choice != keep {
                return .result(dialog: "Left \(workout.displayName) where it was.")
            }
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
        try? context.save()
        // The coach's view of the watch and the plan card's counts. Worth
        // waiting a little for, since the process may sleep once this ends.
        _ = try? await withTimeLimit(8) { await scheduleManager.refreshAfterPlanChange() }

        guard stillOn.isEmpty else {
            return .result(dialog: "\(MissedWorkoutFeedbackSheet.partialMoveMessage(moved: workout, stillOn: stillOn))")
        }
        return .result(dialog: "\(workout.displayName) is on for today.")
    }

    /// "tomorrow", "Sunday", "Sunday 13 December".
    private static func day(_ date: Date) -> String {
        let phrase = IntentPhrasing.when(Calendar.current.startOfDay(for: date))
        return phrase.hasPrefix("on ") ? String(phrase.dropFirst(3)) : phrase
    }
}
