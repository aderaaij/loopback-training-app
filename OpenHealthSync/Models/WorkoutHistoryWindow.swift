//
//  WorkoutHistoryWindow.swift
//  OpenHealthSync
//
//  How far back the app reads workouts from Apple Health: the same window
//  decides what is uploaded to the server and what the Training tab lists.
//  Chosen in Settings → Sync. Health metrics have their own, separate window.
//

import Foundation

nonisolated enum WorkoutHistoryWindow: String, CaseIterable, Identifiable, Sendable {
    case threeMonths
    case sixMonths
    case oneYear
    case twoYears
    case everything

    static let storageKey = "workoutHistoryWindow"
    /// What the app did before this was a setting.
    static let standard: WorkoutHistoryWindow = .sixMonths

    var id: String { rawValue }

    var label: String {
        switch self {
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .oneYear: return "1 year"
        case .twoYears: return "2 years"
        case .everything: return "Everything"
        }
    }

    /// Months back from now; nil means no lower bound.
    private var months: Int? {
        switch self {
        case .threeMonths: return 3
        case .sixMonths: return 6
        case .oneYear: return 12
        case .twoYears: return 24
        case .everything: return nil
        }
    }

    /// The earliest workout start the window covers; nil for everything.
    func startDate(now: Date = Date()) -> Date? {
        guard let months else { return nil }
        return Calendar.current.date(byAdding: .month, value: -months, to: now)
    }

    /// The user's choice, read fresh so background syncs see a change too.
    static var current: WorkoutHistoryWindow {
        UserDefaults.standard.string(forKey: storageKey).flatMap(WorkoutHistoryWindow.init) ?? standard
    }
}
