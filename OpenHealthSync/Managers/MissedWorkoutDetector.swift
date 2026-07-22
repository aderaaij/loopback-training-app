//
//  MissedWorkoutDetector.swift
//  OpenHealthSync
//
//  Compares scheduled workouts against the current date to detect
//  missed (past-due, incomplete) workouts. Filters out workouts
//  that already have feedback entries in SwiftData.
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
        let pastDueIds = pastDue.map(\.plan.id)
        let existingFeedback = fetchExistingFeedbackIds(for: pastDueIds, modelContext: modelContext)

        missedWorkouts = pastDue.compactMap { scheduled -> MissedWorkoutInfo? in
            let workoutId = scheduled.plan.id
            guard !existingFeedback.contains(workoutId) else { return nil }

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

            let scheduledDate = Calendar.current.date(from: scheduled.date) ?? .distantPast

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

    // MARK: - Private

    private func fetchExistingFeedbackIds(
        for workoutIds: [UUID],
        modelContext: ModelContext
    ) -> Set<UUID> {
        let descriptor = FetchDescriptor<WorkoutFeedback>()
        guard let allFeedback = try? modelContext.fetch(descriptor) else {
            return []
        }
        let matchingIds = allFeedback
            .filter { workoutIds.contains($0.workoutId) }
            .map(\.workoutId)
        return Set(matchingIds)
    }
}
