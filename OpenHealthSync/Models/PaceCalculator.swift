//
//  PaceCalculator.swift
//  OpenHealthSync
//
//  Distance, time and pace: any two give the third, plus the split times
//  along the way. Metric inside (meters, seconds, seconds per km) like the
//  rest of the app; the screen converts at its edges. It converts between
//  the three numbers and says nothing about which pace is realistic.
//

import Foundation

/// The race distances offered as presets, and marked in the split table.
nonisolated enum RaceDistance: String, CaseIterable, Identifiable, Sendable {
    case fiveK, tenK, half, marathon

    var id: String { rawValue }

    var meters: Double {
        switch self {
        case .fiveK: 5_000
        case .tenK: 10_000
        case .half: 21_097.5
        case .marathon: 42_195
        }
    }

    var label: String {
        switch self {
        case .fiveK: "5K"
        case .tenK: "10K"
        case .half: "Half"
        case .marathon: "Marathon"
        }
    }
}

nonisolated enum PaceCalculator {
    /// Which of the three is worked out from the other two.
    enum Unknown: String, CaseIterable, Identifiable, Sendable {
        case pace, time, distance

        var id: String { rawValue }

        var label: String {
            switch self {
            case .pace: "Pace"
            case .time: "Time"
            case .distance: "Distance"
            }
        }
    }

    struct Result: Equatable, Sendable {
        let meters: Double
        let seconds: Double

        var secondsPerKm: Double { seconds / (meters / 1000) }
    }

    /// The full picture, given the two that are known. Nil while either is
    /// missing or not above zero; the value passed for the unknown is ignored.
    static func solve(
        for unknown: Unknown,
        meters: Double?,
        seconds: Double?,
        secondsPerKm: Double?
    ) -> Result? {
        func positive(_ value: Double?) -> Double? {
            guard let value, value > 0, value.isFinite else { return nil }
            return value
        }
        switch unknown {
        case .pace:
            guard let meters = positive(meters), let seconds = positive(seconds) else { return nil }
            return Result(meters: meters, seconds: seconds)
        case .time:
            guard let meters = positive(meters), let pace = positive(secondsPerKm) else { return nil }
            return Result(meters: meters, seconds: pace * meters / 1000)
        case .distance:
            guard let seconds = positive(seconds), let pace = positive(secondsPerKm) else { return nil }
            return Result(meters: seconds / pace * 1000, seconds: seconds)
        }
    }

    // MARK: - Splits

    /// One line of the split table: the time on the clock at a mark.
    struct Split: Identifiable, Equatable, Sendable {
        let meters: Double
        let seconds: Double
        /// Whole kilometers or miles covered at this mark; nil between them.
        let unitCount: Int?
        /// "5K", "10K", "Half" or "30K" when the mark is one of those.
        let checkpoint: String?
        let isFinish: Bool

        var id: Double { meters }
    }

    /// The marks a race clock is usually read at, besides every km or mile.
    private static let checkpoints: [(label: String, meters: Double)] = [
        ("5K", 5_000), ("10K", 10_000), ("Half", 21_097.5), ("30K", 30_000),
    ]

    /// Beyond this many kilometers or miles the table keeps to the named
    /// marks and the finish; a row for each would be a list nobody reads.
    private static let maxUnitRows = 200

    /// Time at every whole `unitMeters` (1000 for km, 1609.344 for miles), at
    /// the named checkpoints, and at the finish, in running order. Even pace
    /// throughout. Marks that fall on the same spot share a row, so 5 km is
    /// also the 5K row and a 10 km race ends on a row that is both.
    static func splits(for result: Result, unitMeters: Double) -> [Split] {
        guard unitMeters > 0 else { return [] }
        // Marks within half a meter of each other are the same mark.
        func key(_ meters: Double) -> Int { Int((meters * 2).rounded()) }
        let finishKey = key(result.meters)

        var units: [Int: Int] = [:]
        var names: [Int: String] = [:]
        var positions: [Int: Double] = [finishKey: result.meters]

        let wholeUnits = Int((result.meters / unitMeters + 1e-9).rounded(.down))
        if wholeUnits <= maxUnitRows, wholeUnits > 0 {
            for count in 1...wholeUnits {
                let meters = Double(count) * unitMeters
                units[key(meters)] = count
                positions[key(meters)] = meters
            }
        }
        for checkpoint in checkpoints where key(checkpoint.meters) <= finishKey {
            names[key(checkpoint.meters)] = checkpoint.label
            positions[key(checkpoint.meters)] = checkpoint.meters
        }

        return positions.keys.sorted().map { mark in
            let meters = positions[mark] ?? 0
            return Split(
                meters: meters,
                seconds: result.seconds * meters / result.meters,
                unitCount: units[mark],
                checkpoint: names[mark],
                isFinish: mark == finishKey
            )
        }
    }

    // MARK: - Formatting

    /// "24:51" under an hour, "1:45:00" from there on. Rounded to the second.
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))"
        }
        return "\(minutes):\(String(format: "%02d", secs))"
    }
}
