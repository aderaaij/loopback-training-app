//
//  LastRunIntent.swift
//  OpenHealthSync
//
//  "How was my last run?" Read straight from Health on the phone: the latest
//  run, whether or not it has reached the server yet.
//

import AppIntents
import Foundation

struct LastRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Last Run"
    static let description = IntentDescription("Tells you the distance, time and pace of your most recent run.")
    /// Health can't be read while the phone is locked, so the system asks
    /// for it to be unlocked first.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Dependency private var session: SessionStore
    @Dependency private var workoutManager: WorkoutManager

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard session.isAuthenticated else { throw LoopbackIntentError.notSignedIn }

        let run: WorkoutSummary?
        do {
            run = try await workoutManager.latestRun()
        } catch {
            throw LoopbackIntentError.healthUnreadable
        }
        guard let run else {
            return .result(dialog: "There are no runs in Health yet.")
        }

        let units = DisplayUnits.current
        let day = IntentPhrasing.whenPast(run.startDate)
        let time = IntentPhrasing.duration(run.duration)
        guard let meters = run.distance, meters > 0 else {
            return .result(dialog: "Your last run was \(day): \(time).")
        }
        let pace = units.paceNumber(duration: run.duration, meters: meters)
        return .result(
            dialog: "Your last run was \(day): \(units.distance(meters: meters)) in \(time), at \(pace) per \(units.distanceUnit)."
        )
    }
}
