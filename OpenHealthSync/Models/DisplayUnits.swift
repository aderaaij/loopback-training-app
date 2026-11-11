//
//  DisplayUnits.swift
//  OpenHealthSync
//
//  Display-unit preference (metric / imperial). Display only: HealthKit, the
//  API and everything stored stay metric, and nothing is converted on the
//  wire. Mirrors the dashboard's `format.ts`, but the choice is local to this
//  device — the server doesn't store one.
//

import Foundation

enum DisplayUnits: String, CaseIterable, Identifiable, Sendable {
    case metric
    case imperial

    /// `@AppStorage` key. Unset until the user picks, so the default keeps
    /// following the device's measurement system.
    static let storageKey = "displayUnits"

    /// The device's Measurement System setting (Language & Region), which
    /// defaults from the region and is independent of language. The UK system
    /// counts as imperial: it is its own, but runners there think in miles.
    static var deviceDefault: DisplayUnits {
        Locale.current.measurementSystem == .metric ? .metric : .imperial
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .metric: "Kilometers"
        case .imperial: "Miles"
        }
    }

    // MARK: - Unit labels

    /// "km" / "mi"
    var distanceUnit: String { self == .imperial ? "mi" : "km" }

    /// "/km" / "/mi"
    var paceUnit: String { "/" + distanceUnit }

    private static let metersPerMile = 1609.344

    private var metersPerUnit: Double { self == .imperial ? Self.metersPerMile : 1000 }

    private var lengthUnit: UnitLength { self == .imperial ? .miles : .kilometers }

    // MARK: - Distance

    /// Meters → km or miles.
    func distanceValue(meters: Double) -> Double {
        meters / metersPerUnit
    }

    /// Kilometers → km or miles, for values the server authors in km.
    func distanceValue(km: Double) -> Double {
        distanceValue(meters: km * 1000)
    }

    /// "8.42" — the bare number, for tiles that show the unit separately.
    func distanceNumber(meters: Double) -> String {
        String(format: "%.2f", distanceValue(meters: meters))
    }

    /// "8.42 km" / "5.23 mi"
    func distance(meters: Double) -> String {
        "\(distanceNumber(meters: meters)) \(distanceUnit)"
    }

    /// A distance authored in km or miles, shown in the user's unit. Anything
    /// else (track reps in meters, say) is returned untouched so it reads as
    /// written.
    func preferred(_ distance: Measurement<UnitLength>) -> Measurement<UnitLength> {
        guard distance.unit == .kilometers || distance.unit == .miles else { return distance }
        return distance.converted(to: lengthUnit)
    }

    // MARK: - Pace

    /// "5:42" per km or per mile, from a pace in seconds per km.
    func paceNumber(secondsPerKm: Double) -> String {
        guard secondsPerKm > 0, secondsPerKm.isFinite else { return "--" }
        let perUnit = Int(secondsPerKm * metersPerUnit / 1000)
        return "\(perUnit / 60):\(String(format: "%02d", perUnit % 60))"
    }

    /// "5:42" per km or per mile, from a duration over a distance in meters.
    func paceNumber(duration: TimeInterval, meters: Double) -> String {
        guard meters > 0 else { return "--" }
        return paceNumber(secondsPerKm: duration / (meters / 1000))
    }

    /// "5:42 /km" / "9:10 /mi"
    func pace(duration: TimeInterval, meters: Double) -> String {
        guard meters > 0 else { return "--" }
        return "\(paceNumber(duration: duration, meters: meters)) \(paceUnit)"
    }
}
