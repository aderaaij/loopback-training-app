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

    /// A goal distance in the user's unit. The coach often authors a long run
    /// in meters (11600), which nobody reads as a distance, so a kilometer or
    /// more converts whatever it was written in. Shorter meter distances are
    /// track reps (400 m, 800 m) and read as written in either system.
    func preferred(_ distance: Measurement<UnitLength>) -> Measurement<UnitLength> {
        switch distance.unit {
        case .kilometers, .miles:
            return distance.converted(to: lengthUnit)
        case .meters where distance.value >= 1000:
            return distance.converted(to: lengthUnit)
        default:
            return distance
        }
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

    /// "5:03 – 5:33 /km" from a speed range in m/s, faster end first — the
    /// way a runner reads a target, where the watch alert is stored as speed.
    func paceRange(metersPerSecond slow: Double, _ fast: Double) -> String {
        guard slow > 0, fast > 0 else { return "--" }
        let fastPace = paceNumber(secondsPerKm: 1000 / max(slow, fast))
        let slowPace = paceNumber(secondsPerKm: 1000 / min(slow, fast))
        return "\(fastPace) – \(slowPace) \(paceUnit)"
    }

    // MARK: - Speed

    /// "km/h" / "mph"
    var speedUnit: String { self == .imperial ? "mph" : "km/h" }

    /// "28.5 – 32 km/h" from a speed range in m/s, for activities where
    /// speed, not pace, is the working number (cycling).
    func speedRange(metersPerSecond lower: Double, _ upper: Double) -> String {
        func number(_ mps: Double) -> String {
            let value = mps * 3600 / metersPerUnit
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
        }
        return "\(number(min(lower, upper))) – \(number(max(lower, upper))) \(speedUnit)"
    }
}
