//
//  MissedWorkoutModels.swift
//  OpenHealthSync
//
//  SwiftData model for tracking missed workout feedback.
//  Stores the user's reason for missing and their chosen action
//  (reschedule, adjust plan, or skip).
//

import Foundation
import SwiftData

// MARK: - Enums

enum MissedWorkoutReason: String, Codable, CaseIterable, Identifiable {
    case busy
    case tired
    case weather
    case soreness
    case sick
    case injured
    case motivation
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .busy: return "Too busy"
        case .tired: return "Tired / low energy"
        case .weather: return "Weather"
        case .soreness: return "Sore / minor pain"
        case .sick: return "Sick"
        case .injured: return "Injured"
        case .motivation: return "Not feeling it"
        case .other: return "Other"
        }
    }

    /// The kind of setback this reason opens; nil for everything else.
    var setbackKind: SetbackKind? {
        switch self {
        case .sick: return .illness
        case .injured: return .injury
        default: return nil
        }
    }

    var emoji: String {
        switch self {
        case .busy: return "🗓️"
        case .tired: return "😴"
        case .weather: return "🌧️"
        case .soreness: return "🤕"
        case .sick: return "🤒"
        case .injured: return "🩹"
        case .motivation: return "😐"
        case .other: return "✏️"
        }
    }
}

enum MissedWorkoutAction: String, Codable, CaseIterable {
    case move
    case adjust
    case skip

    var label: String {
        switch self {
        case .move: return "Rescheduled"
        case .adjust: return "Adjusting plan"
        case .skip: return "Skipped"
        }
    }
}

// MARK: - SwiftData Model

@Model
final class WorkoutFeedback {
    var id: UUID
    var workoutId: UUID
    var workoutName: String
    var scheduledDate: Date
    var detectedAt: Date
    var acknowledgedAt: Date?
    var reason: MissedWorkoutReason
    var reasonNote: String?
    var action: MissedWorkoutAction
    var newDate: Date?
    var dismissed: Bool
    var synced: Bool = false

    init(
        workoutId: UUID,
        workoutName: String,
        scheduledDate: Date,
        reason: MissedWorkoutReason,
        action: MissedWorkoutAction,
        reasonNote: String? = nil,
        newDate: Date? = nil
    ) {
        self.id = UUID()
        self.workoutId = workoutId
        self.workoutName = workoutName
        self.scheduledDate = scheduledDate
        self.detectedAt = Date()
        self.acknowledgedAt = Date()
        self.reason = reason
        self.reasonNote = reasonNote
        self.action = action
        self.newDate = newDate
        self.dismissed = false
        self.synced = false
    }
}

extension WorkoutFeedback {
    /// Whether this check-in settles the run scheduled on `date`. A move
    /// re-dates the run, so its check-in only covers the day it left: a moved
    /// run that's missed on its new day needs a check-in of its own.
    func covers(workoutId: UUID, scheduledOn date: Date) -> Bool {
        self.workoutId == workoutId && Calendar.current.isDate(scheduledDate, inSameDayAs: date)
    }

    /// Filed on or before the run's own day: a change of plans rather than a
    /// miss, since a missed run can only be checked in from the next day on.
    var wasFiledAheadOfTime: Bool {
        let calendar = Calendar.current
        guard let acknowledgedAt,
              let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: scheduledDate))
        else { return false }
        return acknowledgedAt < dayAfter
    }

    var payload: WorkoutFeedbackPayload {
        WorkoutFeedbackPayload(
            id: id,
            workoutId: workoutId,
            workoutName: workoutName,
            scheduledDate: scheduledDate,
            detectedAt: detectedAt,
            acknowledgedAt: acknowledgedAt,
            reason: reason.rawValue,
            reasonNote: reasonNote,
            action: action.rawValue,
            newDate: newDate,
            dismissed: dismissed
        )
    }
}

// MARK: - Lightweight Info for Detection

/// Non-persisted struct used by the detector to surface missed workouts to the
/// UI. Also carries a run that isn't due yet into the same sheet, when the
/// athlete moves or skips it ahead of time.
struct MissedWorkoutInfo: Identifiable {
    let id: UUID          // the workout plan ID
    let displayName: String
    let scheduledDate: Date

    /// Due today or later: a change of plans rather than a check-in on a miss.
    var isUpcoming: Bool {
        scheduledDate >= Calendar.current.startOfDay(for: Date())
    }

    /// Planned for a later day than today, so it can be brought forward.
    var canDoToday: Bool {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) else {
            return false
        }
        return scheduledDate >= tomorrow
    }

    /// The run's own time of day on `day`. A bare day would be local
    /// midnight, which the server (bucketing by UTC date) files under the day
    /// before anywhere east of UTC. When that time has already gone by, which
    /// only today can do, it is now instead: a run moved to today is about to
    /// be done, and one planned for hours ago would be too far from the
    /// workout for the two to be matched by time.
    func time(on day: Date, now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: scheduledDate)
        let moved = calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
        guard calendar.isDate(day, inSameDayAs: now), moved < now else { return moved }
        // Whole minutes: the watch schedules by the minute, and the server
        // should hold the same moment.
        return calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)) ?? now
    }
}
