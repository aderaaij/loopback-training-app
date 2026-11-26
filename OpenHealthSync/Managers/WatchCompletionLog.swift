//
//  WatchCompletionLog.swift
//  OpenHealthSync
//
//  When each session on the watch was last seen open and first seen done.
//  WorkoutKit says that a session was ticked off, not when or by which
//  workout. The two sightings bracket that moment, and the workout recorded
//  around then is the one the watch ran for it. That holds on any day, so a
//  session started a day early or late can still be matched to its workout,
//  where matching by planned time gives up or picks the session whose slot
//  the workout happened to land in.
//

import Foundation
import WorkoutKit

struct WatchCompletionLog {
    /// The stretch in which a session went from open to done.
    struct Window: Equatable {
        let lastOpen: Date
        let firstDone: Date

        /// How long the phone may go on showing a session as open after the
        /// watch finished it. The workout and the tick reach the phone
        /// separately, so a sighting of "open" just after a workout ended
        /// doesn't rule that workout out.
        static let syncAllowance: TimeInterval = 3600

        /// Whether a workout over `span` can be the one that did it: it began
        /// before the session was seen done, and didn't end too long before
        /// the session was last seen open.
        func fits(_ span: DateInterval) -> Bool {
            span.start < firstDone && span.end > lastOpen.addingTimeInterval(-Self.syncAllowance)
        }
    }

    /// A session the watch has ticked off and no workout counts for yet.
    struct Ticked {
        let session: UUID
        let activity: String
        let window: Window
    }

    /// A recorded workout that no session counts yet.
    struct Candidate {
        let id: UUID
        let activity: String
        let span: DateInterval
    }

    /// The workout a session was ticked off with: the only one of its
    /// activity that fits its window. Nil when none does, or when two do and
    /// nothing says which.
    static func workout(for session: Ticked, among workouts: [Candidate]) -> UUID? {
        let fitting = workouts.filter { $0.activity == session.activity && session.window.fits($0.span) }
        return fitting.count == 1 ? fitting[0].id : nil
    }

    /// The session ticked off with `workout`: the only one of its activity
    /// whose window it fits, and only when none of the `others` fits that
    /// window as well.
    static func session(for workout: Candidate, ticked: [Ticked], others: [Candidate]) -> UUID? {
        let sessions = ticked.filter { $0.activity == workout.activity && $0.window.fits(workout.span) }
        guard sessions.count == 1, let session = sessions.first else { return nil }
        let rivals = others.filter { $0.id != workout.id }
        return Self.workout(for: session, among: rivals + [workout]) == workout.id ? session.session : nil
    }

    private struct Entry: Codable {
        var lastOpen: Date?
        var firstDone: Date?
        /// A workout has been put forward for it. Once is enough: if the
        /// athlete then unlinks the two, asking again would undo that.
        var offered: Bool?
    }

    private static let key = "watchCompletionLog"
    private var entries: [String: Entry]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    /// Records what the watch reports right now. Sessions it no longer lists
    /// are forgotten.
    mutating func note(_ scheduled: [ScheduledWorkoutPlan], at now: Date = Date()) {
        // An empty list is as likely "not authorised" as an empty schedule,
        // and forgetting everything for it would lose the sightings that a
        // match depends on.
        guard !scheduled.isEmpty else { return }

        var updated: [String: Entry] = [:]
        for item in scheduled {
            let key = item.plan.id.uuidString
            var entry = entries[key] ?? Entry()
            if item.complete {
                if entry.firstDone == nil {
                    entry.firstDone = now
                }
            } else {
                // Open, or open again after being moved or put back.
                entry.lastOpen = now
                entry.firstDone = nil
                entry.offered = nil
            }
            updated[key] = entry
        }
        entries = updated
        save()
    }

    /// Nil unless the session was seen open and then done: one that was
    /// already done at first sight could have been done at any time.
    func window(for id: UUID) -> Window? {
        guard let entry = entries[id.uuidString],
              let lastOpen = entry.lastOpen,
              let firstDone = entry.firstDone
        else { return nil }
        return Window(lastOpen: lastOpen, firstDone: firstDone)
    }

    func wasOffered(_ id: UUID) -> Bool {
        entries[id.uuidString]?.offered == true
    }

    mutating func markOffered(_ id: UUID) {
        guard entries[id.uuidString] != nil else { return }
        entries[id.uuidString]?.offered = true
        save()
    }

    mutating func removeAll() {
        entries = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
