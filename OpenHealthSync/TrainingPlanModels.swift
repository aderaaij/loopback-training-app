//
//  TrainingPlanModels.swift
//  OpenHealthSync
//
//  Created by Claude on 04/04/2026.
//

import Foundation

// MARK: - Plan Lifecycle

/// Where a plan sits relative to today. Date-derived, with an explicit
/// `archived` status from the backend taking precedence.
enum PlanLifecycle: String, Sendable {
    case upcoming
    case current
    case archived

    var label: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .current: return "Current"
        case .archived: return "Archived"
        }
    }
}

// MARK: - Training Plan

nonisolated struct TrainingPlan: Codable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let activityType: String
    let status: String
    let startDate: String
    /// Nullable on the backend — plans without a defined end date are open-ended.
    let endDate: String?
    let description: String?
    let metadata: TrainingPlanMetadata?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, description, metadata
        case activityType = "activity_type"
        case startDate = "start_date"
        case endDate = "end_date"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Parse startDate string to Date
    var start: Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: startDate)
    }

    var end: Date? {
        guard let endDate else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: endDate)
    }

    /// Current week number (0-indexed from start date)
    var currentWeek: Int? {
        guard let start else { return nil }
        let days = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
        return max(0, days / 7)
    }

    /// Total weeks in the plan
    var totalWeeks: Int? {
        guard let start, let end else { return nil }
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return max(1, (days / 7) + 1)
    }

    /// Current phase based on week number
    var currentPhase: PlanPhase? {
        guard let week = currentWeek else { return nil }
        return metadata?.phases?.first { $0.weeks.contains(week) }
    }

    /// Strength cycles are display-only plan markers (Hevy routines per
    /// weekday) — never sent to WorkoutKit / the watch.
    var isStrength: Bool {
        activityType.lowercased() == "strength"
    }

    /// Whole days from today until the plan's end date (0 = ends today,
    /// negative = already ended, nil = open-ended). Drives the cycle-horizon
    /// chip that cues planning the next cycle.
    var daysRemaining: Int? {
        guard let end else { return nil }
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: end)
        ).day
    }

    /// Bucket the plan into upcoming / current / archived.
    ///
    /// An explicit backend status wins: `active` is the current plan (even if it
    /// starts tomorrow) and `archived` is retired (even if its dates haven't
    /// passed). For any other free-form status, dates decide: starting in the
    /// future is upcoming, a passed end date is archived, otherwise current
    /// (including open-ended plans with no end date).
    var lifecycle: PlanLifecycle {
        switch status.lowercased() {
        case "active": return .current
        case "archived": return .archived
        default: break
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        if let start, today < calendar.startOfDay(for: start) {
            return .upcoming
        }
        if let end, today > calendar.startOfDay(for: end) {
            return .archived
        }
        return .current
    }
}

// MARK: - Plan Metadata

struct TrainingPlanMetadata: Codable, Sendable {
    let goals: [PlanGoal]?
    let guardrails: [String]?
    let phases: [PlanPhase]?
    let background: String?
    let athleteContext: AthleteContext?
    /// Weekly cadence for strength cycles. Nested camelCase even though the
    /// surrounding plan read is snake_case — the server stores it verbatim.
    let schedule: PlanSchedule?

    enum CodingKeys: String, CodingKey {
        case goals, guardrails, phases, background, schedule
        case athleteContext = "athlete_context"
    }
}

struct PlanGoal: Codable, Sendable {
    let type: String
    let target: PlanGoalTarget?
    let unit: String?
    let byWeek: Int?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case type, target, unit, description
        case byWeek = "by_week"
    }
}

/// A goal target is free-form on the backend: it can be numeric (e.g. `20` km)
/// or prose (e.g. "pre-op steady pace ~6:00-6:15/km"), depending on the goal
/// type. Decoding it as a single Swift type would fail the whole plan, so it
/// accepts either shape.
enum PlanGoalTarget: Codable, Sendable {
    case number(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .text(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Goal target is neither a number nor a string"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    /// Numeric value when the target is a number, else nil.
    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// Human-readable representation for display.
    var displayString: String {
        switch self {
        case .number(let value):
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value)) : String(value)
        case .text(let value):
            return value
        }
    }
}

struct PlanPhase: Codable, Sendable, Identifiable {
    let name: String
    let weeks: [Int]
    let volumeTargetKm: Double?
    let notes: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, weeks, notes
        case volumeTargetKm = "volume_target_km"
    }
}

struct AthleteContext: Codable, Sendable {
    let age: Int?
    let fitnessLevel: String?
    let constraints: [String]?
    let riskFactors: [String]?

    enum CodingKeys: String, CodingKey {
        case age, constraints
        case fitnessLevel = "fitness_level"
        case riskFactors = "risk_factors"
    }
}

// MARK: - Plan Workout

struct PlanWorkout: Codable, Sendable, Identifiable {
    let id: UUID
    let activityType: String
    let title: String
    let description: String?
    let status: String
    let planId: UUID?
    let createdAt: String?
    /// Nil for legacy queue items inserted by the old backfill migration (pre ~2026-03-18).
    /// For those, fall back to WorkoutScheduleManager.scheduledDate(for:) which reads
    /// the iOS-side scheduledDateMap populated at schedule time.
    let scheduledDate: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status
        case activityType = "activity_type"
        case planId = "plan_id"
        case createdAt = "created_at"
        case scheduledDate = "scheduled_date"
    }
}

// MARK: - Resilient Decoding

/// Wraps a `Decodable` so a single failing element in an array doesn't fail the
/// whole array. Used when decoding plans, whose LLM-authored metadata can drift:
/// `JSONDecoder().decode([FailableDecodable<TrainingPlan>].self, ...)` yields
/// `nil` for any malformed element while keeping the rest. The init never throws,
/// so the surrounding unkeyed container still advances past the bad element.
nonisolated struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Wrapped.self)
    }
}
