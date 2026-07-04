import Foundation
import WorkoutKit

/// A unified representation of any workout-related item on the training timeline.
/// Wraps WorkoutKit scheduled plans, HealthKit workout summaries, and
/// display-only strength sessions from the unified schedule calendar.
enum TrainingTimelineItem: Identifiable {
    case scheduledPlan(ScheduledWorkoutPlan)
    case pastWorkout(WorkoutSummary)
    case strengthSession(CalendarEntry)

    var id: String {
        switch self {
        case .scheduledPlan(let plan):
            return "plan-\(plan.hashValue)"
        case .pastWorkout(let summary):
            return "hk-\(summary.id.uuidString)"
        case .strengthSession(let entry):
            return "strength-\(entry.id)"
        }
    }

    /// The canonical Date for sorting and day-grouping. Strength sessions
    /// carry no time of day, so they sit at local midnight and list first.
    var date: Date {
        switch self {
        case .scheduledPlan(let plan):
            return Calendar.current.date(from: plan.date) ?? .distantPast
        case .pastWorkout(let summary):
            return summary.startDate
        case .strengthSession(let entry):
            return entry.day ?? .distantPast
        }
    }

    /// Day-level DateComponents for dictionary keying.
    var dayComponents: DateComponents {
        Calendar.current.dateComponents([.year, .month, .day], from: date)
    }

    enum DotCategory {
        case upcomingPlan     // blue
        case completedPlan    // green
        case pastWorkout      // orange
        case strengthSession  // violet
    }

    var dotCategory: DotCategory {
        switch self {
        case .scheduledPlan(let plan):
            return plan.complete ? .completedPlan : .upcomingPlan
        case .pastWorkout:
            return .pastWorkout
        case .strengthSession(let entry):
            return entry.completed ? .completedPlan : .strengthSession
        }
    }
}
