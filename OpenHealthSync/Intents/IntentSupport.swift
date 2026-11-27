//
//  IntentSupport.swift
//  OpenHealthSync
//
//  What the Siri and Shortcuts actions in this folder share. An action runs
//  outside the app's screens, often in a process the system started just for
//  it, so nothing has been loaded on its behalf and nobody is watching a
//  spinner: it reads what it needs itself, and gives up on a server that
//  doesn't answer rather than keep Siri waiting.
//
//  The actions get the app's long-lived objects from `AppDependencyManager`,
//  where `LoopbackApp.init` registers them.
//

import AppIntents
import Foundation
import SwiftData
import WorkoutKit

// MARK: - Errors

/// What an action says when it can't do its work.
nonisolated enum LoopbackIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    /// The phone hasn't been allowed to read the watch's schedule yet, which
    /// only the app itself can ask for.
    case scheduleNotAllowed
    case serverUnreachable
    case healthUnreadable
    case runNotFound
    /// The named run is already due today or earlier.
    case notLater(String)
    /// The day asked for is outside the two weeks a run can move within, or
    /// is the day the run already sits on.
    case dayNotAvailable(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn:
            "Sign in to Loopback first."
        case .scheduleNotAllowed:
            "Open Loopback once so it can read your planned runs."
        case .serverUnreachable:
            "Couldn't reach your server, so nothing changed. Try again once you're connected."
        case .healthUnreadable:
            "Couldn't read your runs from Health. Unlock your iPhone and try again."
        case .runNotFound:
            "That run is no longer planned."
        case .notLater(let name):
            "\(name) is already planned for today."
        case .dayNotAvailable(let name):
            "\(name) can move to any other day in the next two weeks."
        }
    }
}

// MARK: - Time limit

/// Runs `work` and cancels it once `seconds` have gone by. A request to a
/// server that can't be reached waits a minute by default, and twice that
/// when it falls back to the other address; an answer can't.
@MainActor
func withTimeLimit<T: Sendable>(
    _ seconds: Double,
    _ work: @escaping @MainActor () async throws -> T
) async throws -> T {
    let task = Task { try await work() }
    let timer = Task {
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

// MARK: - Schedule

extension WorkoutScheduleManager {
    /// Reads the schedule for an action. The links that say which sessions
    /// a workout already counts for come from the last answer the server
    /// gave, kept on disk; this launch's are worth a couple of seconds, no
    /// more. A reachable server answers well inside that.
    func loadScheduleForAction() async throws {
        guard await watchScheduleIsReadable() else {
            throw LoopbackIntentError.scheduleNotAllowed
        }
        _ = try? await withTimeLimit(2.5) { await self.ensureSessionLinks() }
        await loadScheduledWorkouts()
    }
}

extension WorkoutScheduleManager {
    /// What every change of plans made by an action ends with: the check-in
    /// is saved, and the coach's view of the watch and the plan card's counts
    /// are brought up to date. Worth waiting a little for, since the process
    /// may be put to sleep once the action returns.
    func settleChangeFromAction(saving context: ModelContext) async {
        try? context.save()
        _ = try? await withTimeLimit(8) { await self.refreshAfterPlanChange() }
    }
}

/// Whether the phone may read the watch's schedule. Asked here, off any
/// actor, because the state itself isn't Sendable and only the answer needs
/// to travel.
@concurrent nonisolated private func watchScheduleIsReadable() async -> Bool {
    await WorkoutScheduler.shared.authorizationState == .authorized
}

extension MissedWorkoutInfo {
    /// Nil for a session without a readable date, which nothing can be done
    /// with.
    init?(_ scheduled: ScheduledWorkoutPlan) {
        guard let date = Calendar.current.date(from: scheduled.date) else { return nil }
        self.init(id: scheduled.plan.id, displayName: scheduled.plan.displayTitle, scheduledDate: date)
    }
}

// MARK: - Moving onto a day that has a run

extension AppIntent {
    /// A run is moving onto `day`, which may already have one: skip that to
    /// make room, or keep both, as the app asks. Returns the runs to skip,
    /// or nil when the athlete called the move off.
    @MainActor
    func runsToSkip(
        on day: Date,
        for workout: MissedWorkoutInfo,
        in scheduleManager: WorkoutScheduleManager
    ) async throws -> [MissedWorkoutInfo]? {
        let inTheWay = scheduleManager.openSessions(on: day, otherThan: workout.id)
        guard !inTheWay.isEmpty else { return [] }

        let names = inTheWay.map(\.displayName).joined(separator: ", ")
        let skip = IntentChoiceOption(title: "Move & skip \(names)")
        let keep = IntentChoiceOption(title: "Keep both")
        let choice = try await requestChoice(
            between: [skip, keep, .cancel],
            dialog: "You already have \(names) \(IntentPhrasing.day(day))."
        )
        if choice == skip { return inTheWay }
        if choice == keep { return [] }
        return nil
    }
}

// MARK: - Check-ins

/// A context on the store the app's screens keep check-ins in, for an action
/// that files one. Save it when done: nothing autosaves it before the process
/// is put to sleep again.
@MainActor
func feedbackContext() throws -> ModelContext {
    ModelContext(try ModelContainer(for: WorkoutFeedback.self))
}

// MARK: - Wording

nonisolated enum IntentPhrasing {
    /// "today at 18:00", "tomorrow", "on Sunday at 08:00", "on Sunday 13
    /// December". A time of midnight is how "no time" arrives, so it is left
    /// out.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: date)
        let hasTime = (time.hour ?? 0) != 0 || (time.minute ?? 0) != 0
        let at = hasTime ? " at \(date.formatted(date: .omitted, time: .shortened))" : ""

        if calendar.isDate(date, inSameDayAs: now) { return "today\(at)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow\(at)"
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        // Within a week either way the weekday alone says which day.
        if abs(days) < 7 {
            return "on \(date.formatted(.dateTime.weekday(.wide)))\(at)"
        }
        return "on \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))\(at)"
    }

    /// "today", "tomorrow", "on Sunday", "on Sunday 13 December": the day
    /// alone, whatever the time.
    static func day(_ date: Date, now: Date = Date()) -> String {
        when(Calendar.current.startOfDay(for: date), now: now)
    }

    /// "today", "tomorrow", "Sunday", "Sunday 13 December": the day as a
    /// name, for "from Sunday to today".
    static func dayName(_ date: Date, now: Date = Date()) -> String {
        let phrase = day(date, now: now)
        return phrase.hasPrefix("on ") ? String(phrase.dropFirst(3)) : phrase
    }

    /// "today", "yesterday", "on Thursday", "on Thursday 12 November": a day
    /// that has been, so without the time.
    static func whenPast(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days < 7 {
            return "on \(date.formatted(.dateTime.weekday(.wide)))"
        }
        return "on \(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
    }

    /// "44:10", or "1h 23m" from an hour up: as the run's own screen has it.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes):\(String(format: "%02d", Int(seconds) % 60))"
    }

    /// "18 km", "9.5 km", "6.2 mi": a planned distance, which is a round
    /// figure in the unit it was written in and not worth two decimals.
    @MainActor
    static func plannedDistance(meters: Double, units: DisplayUnits) -> String {
        let value = (units.distanceValue(meters: meters) * 10).rounded() / 10
        let number = value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(units.distanceUnit)"
    }
}
