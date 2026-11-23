//
//  ScheduleCalendarModels.swift
//  OpenHealthSync
//
//  Models for the unified schedule calendar (runs + strength sessions) and
//  per-plan cadence. Unlike the plan reads (snake_case), the scheduling
//  endpoints are camelCase, so these decode with default keys.
//
//  Strength sessions are display-only plan markers referencing a Hevy
//  routine — they must never be enqueued to WorkoutKit / the watch.
//

import Foundation

// MARK: - Schedule Kind

nonisolated enum ScheduleKind: String, Codable, Sendable {
    case run
    case strength
}

// MARK: - Calendar Entry (GET /api/schedule/calendar)

nonisolated struct CalendarEntry: Codable, Sendable, Identifiable {
    /// Local calendar day as "yyyy-MM-dd".
    let date: String
    let kind: ScheduleKind
    let title: String
    let activityType: String?
    /// Runs only: pending / fetched / synced / completed.
    let status: String?
    let planId: UUID?
    /// Populated for strength; null for runs.
    let planName: String?
    /// Strength only — the Hevy routine id.
    let routineId: String?
    let completed: Bool
    /// True on both entries when a run and a strength session share a date.
    let conflict: Bool

    var id: String { "\(date)-\(kind.rawValue)-\(title)" }

    /// The entry's day at local midnight.
    var day: Date? { ScheduleDay.date(from: date) }
}

nonisolated struct CalendarResponse: Decodable, Sendable {
    let from: String
    let to: String
    let entries: [CalendarEntry]

    private enum CodingKeys: String, CodingKey { case from, to, entries }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        from = try container.decode(String.self, forKey: .from)
        to = try container.decode(String.self, forKey: .to)
        // One malformed entry (e.g. a future entry kind) shouldn't blank the feed.
        let wrapped = try container.decode([FailableDecodable<CalendarEntry>].self, forKey: .entries)
        entries = wrapped.compactMap(\.value)
    }
}

// MARK: - Plan Cadence (plan.metadata.schedule / GET /api/plans/{id}/schedule)

nonisolated struct RoutineRef: Codable, Sendable {
    let title: String
    let routineId: String?
}

/// A strength session on its own date, outside the weekly cadence.
nonisolated struct DatedSession: Codable, Sendable {
    /// Local calendar day as "yyyy-MM-dd".
    let date: String
    let title: String
    let routineId: String?

    var day: Date? { ScheduleDay.date(from: date) }
}

nonisolated struct PlanSchedule: Codable, Sendable {
    let startDate: String
    let weeks: Int
    /// Weekday key ("mon".."sun") → Hevy routine reference. Empty for a plan
    /// made of sessions on individual dates only.
    let days: [String: RoutineRef]
    /// Sessions on their own dates (server 0.1.26 and later).
    let sessions: [DatedSession]?
    /// Optional default time of day, e.g. "07:00".
    let time: String?
    let timezone: String?

    static let weekdayOrder = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

    /// Cadence entries in mon..sun order (unknown keys sort last).
    var orderedDays: [(weekday: String, routine: RoutineRef)] {
        days
            .map { (weekday: $0.key, routine: $0.value) }
            .sorted {
                (Self.weekdayOrder.firstIndex(of: $0.weekday) ?? .max)
                    < (Self.weekdayOrder.firstIndex(of: $1.weekday) ?? .max)
            }
    }

    /// Compact cadence summary like "Tue Legs · Thu Upper Push". A plan
    /// without a weekly cadence names its next dated sessions instead, like
    /// "Thu 26 Nov Legs · Sat 28 Nov Upper Push". Empty when it has neither.
    var summary: String {
        guard days.isEmpty else {
            return orderedDays
                .map { "\($0.weekday.capitalized) \($0.routine.title)" }
                .joined(separator: " · ")
        }
        let today = Calendar.current.startOfDay(for: Date())
        return (sessions ?? [])
            .compactMap { session in session.day.map { (day: $0, title: session.title) } }
            .filter { $0.day >= today }
            .sorted { $0.day < $1.day }
            .prefix(2)
            .map { "\($0.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \($0.title)" }
            .joined(separator: " · ")
    }
}

nonisolated struct PlanScheduleResponse: Decodable, Sendable {
    let planId: UUID
    /// Nil when the plan has no cadence.
    let schedule: PlanSchedule?
    /// Fully expanded, sorted by date.
    let sessions: [ScheduleSession]
    let warnings: [String]?
}

nonisolated struct ScheduleSession: Decodable, Sendable, Identifiable {
    let date: String
    let weekday: String
    let title: String
    let routineId: String?
    let conflict: Bool
    let conflictsWith: [String]?

    var id: String { "\(date)-\(title)" }

    var day: Date? { ScheduleDay.date(from: date) }
}

// MARK: - Day-string parsing

nonisolated enum ScheduleDay {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
