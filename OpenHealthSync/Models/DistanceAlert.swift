//
//  DistanceAlert.swift
//  OpenHealthSync
//
//  The athlete's choice of a tap on the wrist every so often during a run,
//  like the built-in Workout app's split alerts. WorkoutKit has no such
//  alert for a workout an app schedules, so the choice is carried out by
//  cutting long distance steps into shorter ones (WorkoutCompositionBuilder):
//  the watch announces every step it finishes.
//

import Foundation

nonisolated enum DistanceAlert: String, CaseIterable, Identifiable, Sendable {
    case off
    case kilometer
    case mile
    case custom

    /// `@AppStorage` keys.
    static let storageKey = "distanceAlert"
    static let customValueKey = "distanceAlertCustomValue"

    static let defaultCustomValue = 5
    static let customRange = 2...10

    var id: String { rawValue }

    /// How far apart the alerts are.
    struct Interval: Equatable, Sendable {
        let value: Double
        let unit: UnitLength

        var meters: Double {
            Measurement(value: value, unit: unit).converted(to: .meters).value
        }
    }

    /// The stored choice as a distance, or nil when alerts are off. The
    /// custom distance is in the athlete's display units.
    static func currentInterval(defaults: UserDefaults = .standard) -> Interval? {
        let choice = defaults.string(forKey: storageKey).flatMap(DistanceAlert.init) ?? .off
        switch choice {
        case .off:
            return nil
        case .kilometer:
            return Interval(value: 1, unit: .kilometers)
        case .mile:
            return Interval(value: 1, unit: .miles)
        case .custom:
            let stored = defaults.integer(forKey: customValueKey)
            let value = customRange.contains(stored) ? stored : defaultCustomValue
            return Interval(value: Double(value), unit: customUnit(defaults: defaults))
        }
    }

    static func customUnit(defaults: UserDefaults = .standard) -> UnitLength {
        let imperial: Bool
        switch defaults.string(forKey: "displayUnits") {
        case "imperial": imperial = true
        case "metric": imperial = false
        default: imperial = Locale.current.measurementSystem != .metric
        }
        return imperial ? .miles : .kilometers
    }

    /// How a step of `total` meters is cut for an alert every `every` meters:
    /// `full` steps of that length, then possibly one last step. Nil when the
    /// step is left whole. A short remainder is added to the last full step
    /// rather than getting a step of its own, so nobody is tapped twice in a
    /// hundred meters.
    static func cut(total: Double, every: Double) -> (full: Int, last: Double?)? {
        guard every > 0, total > 0 else { return nil }
        var full = Int((total / every + 1e-6).rounded(.down))
        let remainder = total - Double(full) * every
        var last: Double?
        if remainder >= every * 0.2 {
            last = remainder
        } else if remainder > 1 {
            full -= 1
            last = every + remainder
        }
        guard full >= 1, full > 1 || last != nil else { return nil }
        return (full, last)
    }
}
