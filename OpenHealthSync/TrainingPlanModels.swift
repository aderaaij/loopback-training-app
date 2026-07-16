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
    case completed
    case archived

    var label: String {
        switch self {
        case .upcoming: return "Upcoming"
        case .current: return "Current"
        case .completed: return "Completed"
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
    /// Queue-derived run counts. Only plan *reads* carry it (POST/PATCH
    /// responses default it to null), and strength plans — scheduled via
    /// metadata.schedule, not the queue — always report zeros.
    let progress: PlanProgress?
    /// Server-computed "offer the wrap-up flow" signal. Optional so a read
    /// that omits it can never fail-and-drop the plan via FailableDecodable —
    /// use `isFinishable`. Never derive this client-side; the rule lives on
    /// the server.
    private let finishable: Bool?

    var isFinishable: Bool { finishable ?? false }

    enum CodingKeys: String, CodingKey {
        case id, name, status, description, metadata, progress, finishable
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

    /// Bucket the plan into upcoming / current / completed / archived.
    ///
    /// An explicit backend status wins: `active` is the current plan (even if it
    /// starts tomorrow), `completed` was wrapped up via the celebration flow
    /// (even if it finished early, before its end date), and `archived` is
    /// retired (even if its dates haven't passed). For any other free-form
    /// status, dates decide: starting in the future is upcoming, a passed end
    /// date is archived, otherwise current (including open-ended plans with no
    /// end date).
    var lifecycle: PlanLifecycle {
        switch status.lowercased() {
        case "active": return .current
        case "completed": return .completed
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

// MARK: - Plan Progress

/// Run counts derived from the Apple Watch queue on a plan read.
nonisolated struct PlanProgress: Codable, Sendable {
    let runsTotal: Int
    let runsCompleted: Int
    let runsSkipped: Int
    let runsRemaining: Int

    enum CodingKeys: String, CodingKey {
        case runsTotal = "runs_total"
        case runsCompleted = "runs_completed"
        case runsSkipped = "runs_skipped"
        case runsRemaining = "runs_remaining"
    }
}

// MARK: - Plan Completion

/// Response of `POST /api/plans/{id}/complete`. `nextPlan` is another
/// already-active plan of the same activity type (soonest start first),
/// or nil when nothing is lined up — that's the "talk to your coach" nudge.
nonisolated struct PlanCompletionResponse: Codable, Sendable {
    let plan: TrainingPlan
    let nextPlan: TrainingPlan?

    enum CodingKeys: String, CodingKey {
        case plan
        case nextPlan = "next_plan"
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
