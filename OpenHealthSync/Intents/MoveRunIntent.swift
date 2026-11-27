//
//  MoveRunIntent.swift
//  OpenHealthSync
//
//  "Move my next run": the move the "Change plans" sheet makes for a run
//  that isn't due yet, through the same manager call. It asks for the day
//  and the reason when they weren't given, keeps the run's time of day, and
//  asks what to do when the new day already has a run.
//

import AppIntents
import Foundation
import SwiftData

struct MoveRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Run"
    static let description = IntentDescription(
        "Moves a planned run to another day in the next two weeks, on your watch and for your coach."
    )
    /// It changes the plan, so not from a locked phone.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Run", description: "The run to move. Leave empty for the next one.")
    var run: PlannedRunEntity?

    @Parameter(title: "Day", kind: .date, requestValueDialog: "Which day?")
    var day: Date

    @Parameter(title: "Reason", requestValueDialog: "What's the reason?")
    var reason: MissedWorkoutReason

    @Parameter(title: "Note", description: "Goes with the reasons Other, Sick and Injured.")
    var note: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$run) to \(\.$day)") {
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
            workout = next
        }
        guard workout.canMove(to: day) else {
            throw LoopbackIntentError.dayNotAvailable(workout.displayName)
        }
        if run == nil {
            // Nobody named it, so say which one before it moves.
            let from = IntentPhrasing.dayName(workout.scheduledDate)
            try await requestConfirmation(
                dialog: "Move \(workout.displayName) from \(from) to \(IntentPhrasing.dayName(day))?"
            )
        }

        guard let skipping = try await runsToSkip(on: day, for: workout, in: scheduleManager) else {
            return .result(dialog: "Left \(workout.displayName) where it was.")
        }

        let newDate = workout.time(on: day)
        let reasonNote = reason.note(from: note ?? "")
        let context = try feedbackContext()
        let stillOn: [MissedWorkoutInfo]
        do {
            stillOn = try await withTimeLimit(15) {
                try await scheduleManager.moveUpcoming(
                    workout, to: newDate, reason: reason, note: reasonNote,
                    skipping: skipping, modelContext: context
                )
            }
        } catch {
            throw LoopbackIntentError.serverUnreachable
        }
        let setback = await noteSetback(
            for: reason, note: reasonNote, runDate: workout.scheduledDate, in: setbackStore
        )
        await scheduleManager.settleChangeFromAction(saving: context)

        guard stillOn.isEmpty else {
            return .result(dialog: "\(MissedWorkoutFeedbackSheet.partialMoveMessage(moved: workout, stillOn: stillOn))")
        }
        let moved = "\(workout.displayName) is now \(IntentPhrasing.when(newDate))."
        return .result(dialog: "\([moved, setback].compactMap { $0 }.joined(separator: " "))")
    }
}
