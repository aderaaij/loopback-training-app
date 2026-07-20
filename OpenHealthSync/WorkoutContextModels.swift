//
//  WorkoutContextModels.swift
//  OpenHealthSync
//
//  Wire models for GET /api/workouts/{id}/context — the server's
//  authoritative linkage from a synced workout to the queue item it
//  fulfilled, that item's plan, and any missed-day feedback. Every key is
//  nullable: a freestyle run that never matched a queued session comes back
//  with all-null context, and feedback can outlive its (deleted) queue item.
//
//  All snake_case (workouts resource family). Timestamps are kept as Strings
//  because the backend mixes `Z` / `+00:00` suffixes and some fields carry
//  fractional seconds `.iso8601` can't parse (same issue as
//  PlanNoteModels.swift) — parse leniently via `parseServerDate`.
//
//  Marked `nonisolated` because the project defaults types to @MainActor
//  (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor); without this the Codable
//  conformances couldn't be used from the WorkoutAPIClient actor.
//

import Foundation

nonisolated struct WorkoutContext: Decodable, Sendable {
    let workoutId: String
    let planWorkoutId: String?
    let queueItem: WorkoutContextQueueItem?
    let plan: WorkoutContextPlan?
    let feedback: WorkoutContextFeedback?

    enum CodingKeys: String, CodingKey {
        case plan, feedback
        case workoutId = "workout_id"
        case planWorkoutId = "plan_workout_id"
        case queueItem = "queue_item"
    }
}

/// The queue item this workout fulfilled. `status` is live server state
/// (e.g. "completed", "skipped"), not a snapshot from upload time.
nonisolated struct WorkoutContextQueueItem: Decodable, Sendable {
    let id: String
    let title: String?
    let description: String?
    let activityType: String?
    let status: String?
    let scheduledDate: String?
    let planId: String?
    let completedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status
        case activityType = "activity_type"
        case scheduledDate = "scheduled_date"
        case planId = "plan_id"
        case completedAt = "completed_at"
    }
}

nonisolated struct WorkoutContextPlan: Decodable, Sendable {
    let id: String
    let name: String?
    let activityType: String?
    let status: String?
    let startDate: String?
    let endDate: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case activityType = "activity_type"
        case startDate = "start_date"
        case endDate = "end_date"
    }
}

/// Missed-day feedback keyed by the queue item; survives queue deletion.
/// `reason` / `action` are the same raw strings as MissedWorkoutReason /
/// MissedWorkoutAction, so they map straight onto those enums for display.
nonisolated struct WorkoutContextFeedback: Decodable, Sendable {
    let reason: String?
    let reasonNote: String?
    let action: String?
    let newDate: String?
    let scheduledDate: String?
    let dismissed: Bool?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case reason, action, dismissed
        case reasonNote = "reason_note"
        case newDate = "new_date"
        case scheduledDate = "scheduled_date"
        case createdAt = "created_at"
    }
}

/// Lenient ISO8601 parsing for server timestamps: `Z` or `+00:00` suffix,
/// with or without fractional seconds. Builds formatters per call so it stays
/// usable from any isolation domain.
nonisolated func parseServerDate(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
}
