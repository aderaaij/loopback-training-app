//
//  MissedWorkoutDetector.swift
//  OpenHealthSync
//
//  Compares scheduled workouts against the current date to detect
//  missed (past-due, incomplete) workouts. Filters out workouts
//  already checked in for their current date in SwiftData.
//

import Foundation
import SwiftUI
import SwiftData
import WorkoutKit

@MainActor
@Observable
class MissedWorkoutDetector {
    var missedWorkouts: [MissedWorkoutInfo] = []

    /// Check for missed workouts by comparing the device workout inventory
    /// against the current date. A workout is "missed" if its scheduled date
    /// is before the start of today and it has not been completed.
    func checkForMissedWorkouts(
        scheduledWorkouts: [ScheduledWorkoutPlan],
        modelContext: ModelContext
    ) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())

        // Find past-due, incomplete workouts
        let pastDue = scheduledWorkouts.filter { scheduled in
            guard !scheduled.complete else { return false }
            guard let scheduledDate = calendar.date(from: scheduled.date) else { return false }
            return scheduledDate < startOfToday
        }

        if pastDue.isEmpty {
            missedWorkouts = []
            return
        }

        // Query SwiftData for existing feedback entries to exclude
        let existingFeedback = (try? modelContext.fetch(FetchDescriptor<WorkoutFeedback>())) ?? []

        missedWorkouts = pastDue.compactMap { scheduled -> MissedWorkoutInfo? in
            let workoutId = scheduled.plan.id
            let scheduledDate = Calendar.current.date(from: scheduled.date) ?? .distantPast
            guard !existingFeedback.contains(where: { $0.covers(workoutId: workoutId, scheduledOn: scheduledDate) }) else {
                return nil
            }

            let name: String
            switch scheduled.plan.workout {
            case .custom(let custom):
                name = custom.displayName ?? "Custom Workout"
            case .goal(let goal):
                name = "Goal: \(goal.activity.displayName)"
            case .pacer(let pacer):
                name = "Pacer: \(pacer.activity.displayName)"
            case .swimBikeRun:
                name = "Swim-Bike-Run"
            @unknown default:
                name = "Workout"
            }

            return MissedWorkoutInfo(
                id: workoutId,
                displayName: name,
                scheduledDate: scheduledDate
            )
        }
        .sorted { $0.scheduledDate > $1.scheduledDate } // newest miss first
    }

    /// Dismiss a missed workout without providing feedback.
    /// Creates a dismissed feedback entry so it won't be flagged again.
    func dismiss(workout: MissedWorkoutInfo, modelContext: ModelContext) {
        let feedback = WorkoutFeedback(
            workoutId: workout.id,
            workoutName: workout.displayName,
            scheduledDate: workout.scheduledDate,
            reason: .other,
            action: .skip
        )
        feedback.dismissed = true
        feedback.acknowledgedAt = nil
        modelContext.insert(feedback)

        missedWorkouts.removeAll { $0.id == workout.id }
    }

    /// Check if a specific workout plan ID is in the current missed workouts list.
    func isMissed(workoutId: UUID) -> Bool {
        missedWorkouts.contains { $0.id == workoutId }
    }

    /// Returns the MissedWorkoutInfo for a given workout ID, if it's missed.
    func missedInfo(for workoutId: UUID) -> MissedWorkoutInfo? {
        missedWorkouts.first { $0.id == workoutId }
    }
}
