//
//  RunningWorkoutModels.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 14/03/2026.
//

import Foundation

// MARK: - Extraction Status

enum WorkoutExtractionStatus: Equatable {
    case notExtracted
    case extracting
    case sending
    case sent(Date)
    case failed(String)
}

// MARK: - Detailed Workout

struct DetailedWorkout: Codable, Sendable {
    let id: UUID
    let planWorkoutId: UUID?
    let activityType: String
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval
    let totalDistance: Double?             // meters
    let totalEnergyBurned: Double?        // kcal
    let source: String
    let sourceName: String?               // human-readable HKSource.name, display-only
    let route: [RoutePoint]?
    let heartRate: [TimeSeries]?          // bpm
    let cadence: [TimeSeries]?            // steps/min
    let power: [TimeSeries]?              // watts
    let speed: [TimeSeries]?              // m/s
    let strideLength: [TimeSeries]?       // meters
    let verticalOscillation: [TimeSeries]? // centimeters
    let groundContactTime: [TimeSeries]?  // milliseconds
    let splits: [Split]?
    let activities: [WorkoutActivityData]?  // structured intervals / multisport segments
    let events: [WorkoutEventData]?
    let metadata: [String: String]?
    let effortScore: Double?              // user-rated RPE 1–10 (Apple Watch post-workout)
    let estimatedEffortScore: Double?     // system-estimated RPE 1–10
    let endHeartRate: Double?             // bpm as the workout ended
    let heartRateAfter1Min: Double?       // bpm one minute after the end
    let heartRateAfter2Min: Double?       // bpm two minutes after the end
    let vo2Max: Double?                   // mL/kg/min, the estimate Health recorded for this workout

    /// The readings after the end, when there are enough to show a drop.
    var heartRateRecovery: HeartRateRecovery? {
        guard let endHeartRate, let heartRateAfter1Min else { return nil }
        return HeartRateRecovery(atEnd: endHeartRate, afterOneMinute: heartRateAfter1Min,
                                 afterTwoMinutes: heartRateAfter2Min)
    }
}

// MARK: - Heart Rate Recovery

/// Heart rate as a workout ended and in the two minutes after it. The watch
/// keeps measuring for a few minutes once a workout is over; the drop from the
/// end reading is the recovery figure Fitness shows.
struct HeartRateRecovery: Sendable, Equatable {
    let atEnd: Double
    let afterOneMinute: Double
    let afterTwoMinutes: Double?

    var dropAfterOneMinute: Int { Int((atEnd - afterOneMinute).rounded()) }
    var dropAfterTwoMinutes: Int? { afterTwoMinutes.map { Int((atEnd - $0).rounded()) } }

    /// How far before the end a reading still counts as the end reading.
    private static let endLookback: TimeInterval = 20
    /// How far from the minute mark a reading may sit and still stand for it.
    private static let markTolerance: TimeInterval = 10
    /// A pause running into the end longer than this means the athlete had
    /// already stopped: the heart rate fell before the workout was ended, and
    /// what is left to measure says nothing.
    private static let longestTrailingPause: TimeInterval = 30

    /// Picks the three readings out of heart rate samples around a workout's
    /// end. Returns nil rather than a figure that would mislead: no reading
    /// close to the end, none close to the one-minute mark, or a workout that
    /// sat paused before it was ended.
    static func measure(samples: [TimeSeries], workoutEnd: Date, pauses: [DateInterval]) -> HeartRateRecovery? {
        if let last = pauses.max(by: { $0.end < $1.end }),
           last.end >= workoutEnd.addingTimeInterval(-1),
           last.duration > longestTrailingPause {
            return nil
        }

        let valid = samples.filter { $0.value > 0 }
        let atEnd = valid
            .filter { $0.timestamp <= workoutEnd.addingTimeInterval(2)
                && $0.timestamp >= workoutEnd.addingTimeInterval(-endLookback) }
            .max { $0.timestamp < $1.timestamp }

        func reading(after seconds: TimeInterval) -> Double? {
            let mark = workoutEnd.addingTimeInterval(seconds)
            return valid
                .filter { abs($0.timestamp.timeIntervalSince(mark)) <= markTolerance }
                .min { abs($0.timestamp.timeIntervalSince(mark)) < abs($1.timestamp.timeIntervalSince(mark)) }?
                .value
        }

        guard let atEnd, let one = reading(after: 60) else { return nil }
        return HeartRateRecovery(atEnd: atEnd.value, afterOneMinute: one, afterTwoMinutes: reading(after: 120))
    }
}

// MARK: - Route

struct RoutePoint: Codable, Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let course: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
}

// MARK: - Time Series

struct TimeSeries: Codable, Sendable {
    let timestamp: Date
    let value: Double
}

// MARK: - Splits

struct Split: Codable, Sendable {
    let index: Int
    let distance: Double                  // meters
    let duration: TimeInterval            // seconds
    let pace: Double                      // seconds per km
    let averageHeartRate: Double?         // bpm
    let averageCadence: Double?           // steps/min
    let averagePower: Double?             // watts
    let elevationGain: Double?            // meters
    let elevationLoss: Double?            // meters
    let startDate: Date
    let endDate: Date
}

// MARK: - Workout Activities (intervals, multisport segments)

struct WorkoutActivityData: Codable, Sendable {
    let activityType: String              // e.g. "running", "transition"
    let startDate: Date
    let endDate: Date
    let duration: TimeInterval            // seconds
    let totalDistance: Double?             // meters
    let totalEnergyBurned: Double?        // kcal
    let averageHeartRate: Double?         // bpm
    let events: [WorkoutEventData]?
    let metadata: [String: String]?
}

// MARK: - Workout Events

struct WorkoutEventData: Codable, Sendable {
    let type: String
    let startDate: Date
    let endDate: Date
    let metadata: [String: String]?
}

// MARK: - Workout Summary (for list display)

struct WorkoutSummary: Identifiable {
    let id: UUID
    let activityType: String
    let activityName: String
    let startDate: Date
    let duration: TimeInterval
    let distance: Double?
}
