//
//  RetiredSessionStore.swift
//  OpenHealthSync
//
//  Planned sessions that were taken off the watch because a workout recorded
//  some other way counts for them. The watch only ticks off a session that
//  was started from its own schedule, so one done in the built-in Workout
//  app would otherwise keep being offered there. The app's calendar and
//  lists are built from the watch's schedule, so the session is kept here,
//  steps and all, and keeps its row.
//

import Foundation
import WorkoutKit
import os

struct RetiredSessionStore {
    private struct Entry: Codable {
        let plan: Data
        let date: DateComponents
    }

    private(set) var sessions: [UUID: ScheduledWorkoutPlan] = [:]
    private var entries: [String: Entry] = [:]

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("retired-sessions.json")
    }

    init() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return }
        entries = decoded
        for (key, entry) in decoded {
            guard let id = UUID(uuidString: key), let plan = try? WorkoutPlan(from: entry.plan) else { continue }
            sessions[id] = ScheduledWorkoutPlan(plan, date: entry.date)
        }
    }

    /// Keeps a session. False when it couldn't be stored, and then it must
    /// stay on the watch: removing it would lose it altogether.
    mutating func add(_ scheduled: ScheduledWorkoutPlan) -> Bool {
        guard let data = try? scheduled.plan.dataRepresentation else { return false }
        var updated = entries
        updated[scheduled.plan.id.uuidString] = Entry(plan: data, date: scheduled.date)
        guard write(updated) else { return false }
        entries = updated
        sessions[scheduled.plan.id] = ScheduledWorkoutPlan(scheduled.plan, date: scheduled.date)
        return true
    }

    /// Forgets a session. False when it wasn't kept here.
    @discardableResult
    mutating func remove(id: UUID) -> Bool {
        guard sessions.removeValue(forKey: id) != nil else { return false }
        entries.removeValue(forKey: id.uuidString)
        write(entries)
        return true
    }

    mutating func removeAll() {
        sessions = [:]
        entries = [:]
        write(entries)
    }

    @discardableResult
    private func write(_ entries: [String: Entry]) -> Bool {
        do {
            let url = Self.fileURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            return true
        } catch {
            AppLog.scheduling.error("Failed to store retired sessions: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
