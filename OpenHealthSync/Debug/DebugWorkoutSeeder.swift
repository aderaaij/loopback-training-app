//
//  DebugWorkoutSeeder.swift
//  OpenHealthSync
//
//  DEBUG-only HealthKit seeder for the simulator: writes ~6 months of
//  realistic runs (distance, energy, heart-rate series, GPS route around
//  Lisbon) plus weekly strength sessions, so the workout list, detail charts,
//  and splits all have data without a real watch. Last Saturday's long run
//  carries a mid-run pause as the regression case for pause-aware splits.
//
//  The whole file is compiled out of Release builds. By default seeded
//  workouts are marked as already-synced (same UserDefaults key
//  WorkoutManager uses) because BackgroundSyncManager auto-uploads anything
//  unsent — seeding must not push fake runs to a real account. Untick the
//  toggle in Settings → Developer only when signed into a test account.
//

#if DEBUG

import Foundation
import Observation
import HealthKit
import CoreLocation

/// Deterministic SplitMix64 generator so the demo seeds identically every run
/// (a real demo should not roll up sparse or lopsided by chance).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
@Observable
final class DebugWorkoutSeeder {
    var isWorking = false
    var statusMessage: String?

    private let healthStore = HKHealthStore()

    /// Fixed RNG seed so the demo story is reproducible across runs. ("SOFIA")
    private static let demoSeed: UInt64 = 0x53_4F_46_49_41

    private enum RunKind { case easy, tempo, intervals, long }

    private static let heartRateType = HKQuantityType(.heartRate)
    private static let distanceType = HKQuantityType(.distanceWalkingRunning)
    private static let energyType = HKQuantityType(.activeEnergyBurned)

    /// Daily-health types seeded alongside the workouts, so every data domain
    /// (recovery, body, activity, nutrition) has recent readings in the
    /// simulator — not just training.
    private static let healthQuantityTypes: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .respiratoryRate, .oxygenSaturation,
        .bodyMass, .bodyFatPercentage, .leanBodyMass, .vo2Max,
        .stepCount, .basalEnergyBurned,
        .dietaryEnergyConsumed, .dietaryProtein, .dietaryCarbohydrates,
        .dietaryFatTotal, .dietaryFiber,
    ]

    private static let shareTypes: Set<HKSampleType> = {
        var types: Set<HKSampleType> = [
            HKWorkoutType.workoutType(),
            heartRateType,
            distanceType,
            energyType,
            HKSeriesType.workoutRoute(),
            HKCategoryType(.sleepAnalysis),
        ]
        for id in healthQuantityTypes { types.insert(HKQuantityType(id)) }
        return types
    }()

    /// Lisbon riverfront path, Alcântara → Belém — the same waypoints as the
    /// server's `scripts/seed_demo.py`, so the app-seeded and server-seeded
    /// demos draw the same route. (A straight line from Praça do Comércio put
    /// the runner in the Tagus.)
    private static let routeWaypoints: [CLLocationCoordinate2D] = [
        CLLocationCoordinate2D(latitude: 38.70450, longitude: -9.17540),
        CLLocationCoordinate2D(latitude: 38.70180, longitude: -9.18240),
        CLLocationCoordinate2D(latitude: 38.69890, longitude: -9.19110),
        CLLocationCoordinate2D(latitude: 38.69720, longitude: -9.19980),
        CLLocationCoordinate2D(latitude: 38.69510, longitude: -9.20820),
        CLLocationCoordinate2D(latitude: 38.69260, longitude: -9.21600),
    ]

    // MARK: - Seeding

    /// Seeds ~26 weeks of workouts: three runs a week (Mon easy / Wed quality /
    /// Sat long) plus a strength session every other week. Runs are anchored to
    /// real weekdays and generated from a fixed seed so the story is
    /// reproducible and lines up with the server demo's Mon/Wed/Sat plan days.
    ///
    /// Note: this and the server's `scripts/seed_demo.py` only coincide when
    /// both are run on the same calendar day against the same "today" — they
    /// each compute this week's Monday independently.
    func seed(markAsSynced: Bool) async {
        isWorking = true
        statusMessage = "Requesting HealthKit write access…"
        defer { isWorking = false }

        do {
            try await healthStore.requestAuthorization(toShare: Self.shareTypes, read: [])

            var rng = SeededGenerator(seed: Self.demoSeed)
            var seededIDs: [UUID] = []
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let weeks = 26

            // This week's Monday, computed locale-independently, so runs land on
            // real Mon/Wed/Sat no matter which weekday we seed on.
            let weekday = calendar.component(.weekday, from: today)   // 1=Sun…7=Sat
            let daysSinceMonday = (weekday + 5) % 7
            let currentMonday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today)!

            for week in 0..<weeks {
                statusMessage = "Seeding week \(week + 1) of \(weeks)…"
                let weekMonday = calendar.date(byAdding: .day, value: -(week * 7), to: currentMonday)!

                // Mon easy / Wed quality / Sat long, each a distinct kind.
                let runs: [(offset: Int, kind: RunKind, isWednesday: Bool)] = [
                    (0, .easy, false),
                    (2, qualityKind(week: week), true),
                    (5, .long, false),
                ]
                for run in runs {
                    // Deterministic miss: the Wednesday of plan week 3 stays
                    // empty — the demo server queues a skipped-with-feedback
                    // item there, and a local run would contradict it.
                    if run.isWednesday && planWeek(for: week) == 3 { continue }

                    guard let day = calendar.date(byAdding: .day, value: run.offset, to: weekMonday),
                          day < Date() else { continue }
                    let km = run.kind == .long
                        ? Double.random(in: 12...18, using: &rng)
                        : Double.random(in: 5...9, using: &rng)
                    let start = calendar.date(byAdding: .minute,
                                              value: 6 * 60 + 40 + Int.random(in: -5...5, using: &rng),
                                              to: day)!
                    // Regression case for pause-aware splits: last Saturday's
                    // long run gets a 3.5-minute stop ~20 minutes in (pause/
                    // resume events, route gap, recovering HR). The split
                    // containing it must pace like its neighbours and its HR
                    // average must ignore the recovery dip.
                    let pause: (at: TimeInterval, duration: TimeInterval)? =
                        (week == 1 && run.kind == .long) ? (at: 1230, duration: 210) : nil
                    if let id = try await seedRun(start: start, km: km, kind: run.kind,
                                                  pause: pause, rng: &rng) {
                        seededIDs.append(id)
                    }
                }

                // Strength: Tuesday of every other week, anchored to the weekday.
                if week.isMultiple(of: 2) {
                    if let day = calendar.date(byAdding: .day, value: 1, to: weekMonday),
                       day < Date() {
                        let start = calendar.date(byAdding: .hour, value: 18, to: day)!
                        if let id = try await seedStrength(start: start, rng: &rng) {
                            seededIDs.append(id)
                        }
                    }
                }
            }

            if markAsSynced {
                markSent(seededIDs)
            }

            // After the workouts, so their random sequence — and with it the
            // demo story — is unchanged by the health samples.
            statusMessage = "Seeding daily health data…"
            let healthCount = try await seedHealthSamples(rng: &rng)

            statusMessage = "Seeded \(seededIDs.count) workouts\(markAsSynced ? " (marked as synced)" : "") and \(healthCount) health samples."
        } catch {
            statusMessage = "Seeding failed: \(error.localizedDescription)"
        }
    }

    /// Plan week number for a week index (0 = current). The demo's 8-week plan
    /// started 4 weeks ago, so this week is plan week 5 and 4 weeks back is plan
    /// week 1. Returns nil for weeks before the plan.
    private func planWeek(for week: Int) -> Int? {
        let n = 5 - week
        return (1...5).contains(n) ? n : nil
    }

    /// The Wednesday "quality" session kind. Inside the plan, odd plan weeks are
    /// interval days and even ones tempo; earlier history alternates tempo/easy.
    private func qualityKind(week: Int) -> RunKind {
        if let pw = planWeek(for: week) {
            return pw.isMultiple(of: 2) ? .tempo : .intervals
        }
        let historyWeek = week - 4
        return historyWeek.isMultiple(of: 2) ? .easy : .tempo
    }

    /// One outdoor run: paced distance + energy + HR samples and a GPS
    /// out-and-back route along the Tejo. `pause` inserts a mid-run stop at
    /// the given moving-time offset: samples after it shift by the pause
    /// length, the route gets a gap, HR keeps recording (recovering), and
    /// matching pause/resume workout events are written.
    private func seedRun(start: Date, km: Double, kind: RunKind,
                         pause: (at: TimeInterval, duration: TimeInterval)? = nil,
                         rng: inout SeededGenerator) async throws -> UUID? {
        let paceSecPerKm = Double.random(in: 315...400, using: &rng)   // 5:15–6:40 /km
        let duration = km * paceSecPerKm                               // moving time
        let end = start.addingTimeInterval(duration + (pause?.duration ?? 0))
        let speed = km * 1000 / duration                               // m/s

        // Moving-time offset → wall-clock date. Interval starts shift when
        // they begin at or after the pause; ends and instants only when
        // strictly past it, so no sample straddles the paused window.
        func wallStart(_ t: TimeInterval) -> Date {
            start.addingTimeInterval(pause.map { t >= $0.at ? t + $0.duration : t } ?? t)
        }
        func wallPoint(_ t: TimeInterval) -> Date {
            start.addingTimeInterval(pause.map { t > $0.at ? t + $0.duration : t } ?? t)
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config, device: .local())
        try await builder.beginCollection(at: start)

        if let pause {
            try await builder.addWorkoutEvents([
                HKWorkoutEvent(type: .pause,
                               dateInterval: DateInterval(start: start.addingTimeInterval(pause.at), duration: 0),
                               metadata: nil),
                HKWorkoutEvent(type: .resume,
                               dateInterval: DateInterval(start: start.addingTimeInterval(pause.at + pause.duration), duration: 0),
                               metadata: nil),
            ])
        }

        var samples: [HKSample] = []

        // Distance + energy in 30s slices (gives the extractor real splits).
        let slice: TimeInterval = 30
        var t: TimeInterval = 0
        while t < duration {
            let sliceEnd = min(t + slice, duration)
            let sliceMeters = speed * (sliceEnd - t) * Double.random(in: 0.92...1.08, using: &rng)
            let sliceKcal = (sliceMeters / 1000) * 65
            samples.append(HKQuantitySample(
                type: Self.distanceType,
                quantity: HKQuantity(unit: .meter(), doubleValue: sliceMeters),
                start: wallStart(t),
                end: wallPoint(sliceEnd)
            ))
            samples.append(HKQuantitySample(
                type: Self.energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: sliceKcal),
                start: wallStart(t),
                end: wallPoint(sliceEnd)
            ))
            t = sliceEnd
        }

        // HR shape depends on the session kind; intervals oscillate so the
        // detail chart makes interval days unmistakable.
        switch kind {
        case .intervals:
            samples.append(contentsOf: intervalHeartRateSamples(
                start: start, duration: duration, rng: &rng
            ))
        case .tempo:
            samples.append(contentsOf: heartRateSamples(
                start: start, duration: duration, warmupFrom: 130, steady: 162,
                cooldownTo: 135, pause: pause, rng: &rng
            ))
        case .long:
            samples.append(contentsOf: heartRateSamples(
                start: start, duration: duration, warmupFrom: 108, steady: 144,
                pause: pause, rng: &rng
            ))
        case .easy:
            samples.append(contentsOf: heartRateSamples(
                start: start, duration: duration, warmupFrom: 108, steady: 141,
                pause: pause, rng: &rng
            ))
        }

        try await builder.addSamples(samples)
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return nil }

        // Out-and-back route: east along the river, then retrace.
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
        try await routeBuilder.insertRouteData(routeLocations(
            start: start, duration: duration, speed: speed, pause: pause, rng: &rng
        ))
        try await routeBuilder.finishRoute(with: workout, metadata: nil)

        return workout.uuid
    }

    /// One indoor strength session: energy + HR only, no distance/route.
    private func seedStrength(start: Date, rng: inout SeededGenerator) async throws -> UUID? {
        let duration = TimeInterval(Int.random(in: 35...55, using: &rng) * 60)
        let end = start.addingTimeInterval(duration)

        let config = HKWorkoutConfiguration()
        // Must be traditionalStrength (uploads as "traditionalStrength") so the
        // server's strength-schedule auto-matching and the dashboard activity
        // map recognise it — see TrainingCalendarView.swift's matching on that
        // key. functionalStrengthTraining would render as generic "other".
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor

        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config, device: .local())
        try await builder.beginCollection(at: start)

        var samples: [HKSample] = [
            HKQuantitySample(
                type: Self.energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: duration / 60 * 5.5),
                start: start,
                end: end
            ),
        ]
        samples.append(contentsOf: heartRateSamples(
            start: start, duration: duration, warmupFrom: 90,
            steady: Double.random(in: 115...135, using: &rng), rng: &rng
        ))

        try await builder.addSamples(samples)
        try await builder.endCollection(at: end)
        return try await builder.finishWorkout()?.uuid
    }

    private func heartRateSamples(start: Date, duration: TimeInterval,
                                  warmupFrom: Double, steady: Double,
                                  cooldownTo: Double? = nil,
                                  pause: (at: TimeInterval, duration: TimeInterval)? = nil,
                                  rng: inout SeededGenerator) -> [HKSample] {
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let warmup = min(300.0, duration / 4)
        let cooldown = cooldownTo == nil ? 0 : min(600.0, duration / 4)
        let cooldownStart = max(warmup, duration - cooldown)
        var samples: [HKSample] = []
        var t: TimeInterval = 0
        while t < duration {
            let base: Double
            if t < warmup {
                base = warmupFrom + (steady - warmupFrom) * (t / warmup)
            } else if let cooldownTo, cooldown > 0, t >= cooldownStart {
                base = steady + (cooldownTo - steady) * ((t - cooldownStart) / cooldown)
            } else {
                base = steady
            }
            let bpm = base + Double.random(in: -4...4, using: &rng)
            let wallOffset = pause.map { t > $0.at ? t + $0.duration : t } ?? t
            let at = start.addingTimeInterval(wallOffset)
            samples.append(HKQuantitySample(
                type: Self.heartRateType,
                quantity: HKQuantity(unit: bpmUnit, doubleValue: bpm),
                start: at,
                end: at
            ))
            t += 15
        }

        // The watch keeps recording HR through a pause, decaying toward rest —
        // exactly the samples the extractor must exclude from split averages.
        if let pause {
            var pt: TimeInterval = 15
            while pt < pause.duration {
                let bpm = steady - (steady - 96) * min(1, pt / 120)
                    + Double.random(in: -3...3, using: &rng)
                let at = start.addingTimeInterval(pause.at + pt)
                samples.append(HKQuantitySample(
                    type: Self.heartRateType,
                    quantity: HKQuantity(unit: bpmUnit, doubleValue: bpm),
                    start: at,
                    end: at
                ))
                pt += 15
            }
        }
        return samples
    }

    /// Warmup → repeated hard/float intervals → cooldown, so the HR chart on a
    /// plan-week interval run shows unmistakable oscillation.
    private func intervalHeartRateSamples(start: Date, duration: TimeInterval,
                                          rng: inout SeededGenerator) -> [HKSample] {
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let warmup = min(900.0, duration * 0.3)
        let cooldown = min(600.0, duration * 0.25)
        let workEnd = max(warmup, duration - cooldown)
        var samples: [HKSample] = []
        var t: TimeInterval = 0
        while t < duration {
            let base: Double
            if t < warmup {
                base = 118 + (126 - 118) * (t / warmup)
            } else if t < workEnd {
                // 180s hard @ ~169, 90s float @ ~141.
                let phase = (t - warmup).truncatingRemainder(dividingBy: 270)
                base = phase < 180 ? 169 : 141
            } else {
                base = 132
            }
            let bpm = base + Double.random(in: -3...3, using: &rng)
            let at = start.addingTimeInterval(t)
            samples.append(HKQuantitySample(
                type: Self.heartRateType,
                quantity: HKQuantity(unit: bpmUnit, doubleValue: bpm),
                start: at,
                end: at
            ))
            t += 15
        }
        return samples
    }

    private func routeLocations(start: Date, duration: TimeInterval, speed: Double,
                                pause: (at: TimeInterval, duration: TimeInterval)? = nil,
                                rng: inout SeededGenerator) -> [CLLocation] {
        let interval: TimeInterval = 15
        let halfway = duration / 2
        let metersPerDegreeLat = 111_111.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(Self.routeWaypoints[0].latitude * .pi / 180)

        // Cumulative metres along the waypoint path.
        var cumulative: [Double] = [0]
        for (a, b) in zip(Self.routeWaypoints, Self.routeWaypoints.dropFirst()) {
            let dy = (b.latitude - a.latitude) * metersPerDegreeLat
            let dx = (b.longitude - a.longitude) * metersPerDegreeLon
            cumulative.append(cumulative.last! + (dx * dx + dy * dy).squareRoot())
        }
        let pathLength = cumulative.last!

        var locations: [CLLocation] = []
        var t: TimeInterval = 0
        while t <= duration {
            // Distance from the start of the out-and-back. Runs longer than
            // twice the path fold back along it rather than running off its end.
            let along = t <= halfway ? speed * t : speed * (duration - t)
            var onPath = along.truncatingRemainder(dividingBy: 2 * pathLength)
            if onPath > pathLength { onPath = 2 * pathLength - onPath }

            let segment = min(cumulative.lastIndex { $0 <= onPath } ?? 0, Self.routeWaypoints.count - 2)
            let from = Self.routeWaypoints[segment], to = Self.routeWaypoints[segment + 1]
            let segmentLength = cumulative[segment + 1] - cumulative[segment]
            let fraction = segmentLength > 0 ? (onPath - cumulative[segment]) / segmentLength : 0
            // GPS-like jitter, kept small so the trace stays on the promenade.
            let jitter = Double.random(in: -4...4, using: &rng)

            // Route collection stops while paused: points after the pause
            // shift by its length, leaving the wall-clock gap the extractor
            // has to subtract from the enclosing split.
            let wallOffset = pause.map { t > $0.at ? t + $0.duration : t } ?? t
            locations.append(CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * fraction
                        + jitter / metersPerDegreeLat,
                    longitude: from.longitude + (to.longitude - from.longitude) * fraction
                ),
                altitude: 8,
                horizontalAccuracy: 5,
                verticalAccuracy: 8,
                timestamp: start.addingTimeInterval(wallOffset)
            ))
            t += interval
        }
        return locations
    }

    // MARK: - Daily health data

    /// Thirty days of the non-workout data the other domains read: nightly
    /// sleep stages, morning recovery readings, weekly body measurements,
    /// daily steps and resting energy, and logged food. Values wander around a
    /// plausible recreational runner's baseline; nothing here is tuned to the
    /// training load.
    private func seedHealthSamples(rng: inout SeededGenerator) async throws -> Int {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var objects: [HKObject] = []

        func quantity(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit,
                      from start: Date, to end: Date? = nil) {
            let end = end ?? start
            guard end <= now else { return }
            objects.append(HKQuantitySample(type: HKQuantityType(id),
                                            quantity: HKQuantity(unit: unit, doubleValue: value),
                                            start: start, end: end))
        }

        let perMinute = HKUnit.count().unitDivided(by: .minute())
        let kcal = HKUnit.kilocalorie()
        let gram = HKUnit.gram()

        for daysAgo in 0..<30 {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            func at(_ hour: Int, _ minute: Int = 0) -> Date {
                calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
            }

            // Sleep: the night ending this morning, as repeating stage cycles.
            let wake = at(6, 10 + Int.random(in: 0...25, using: &rng))
            var cursor = wake.addingTimeInterval(-Double.random(in: 6.6...8.1, using: &rng) * 3600)
            let cycle: [(HKCategoryValueSleepAnalysis, ClosedRange<Double>)] = [
                (.asleepCore, 28...45), (.asleepDeep, 14...26), (.asleepCore, 18...30), (.asleepREM, 14...26),
            ]
            var stage = 0
            while cursor < wake {
                let (value, minutes) = cycle[stage % cycle.count]
                var end = min(cursor.addingTimeInterval(Double.random(in: minutes, using: &rng) * 60), wake)
                // One short awakening a night, after the second cycle.
                if stage == 8, cursor.addingTimeInterval(240) <= now {
                    end = min(cursor.addingTimeInterval(240), wake)
                    objects.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis),
                                                    value: HKCategoryValueSleepAnalysis.awake.rawValue,
                                                    start: cursor, end: end))
                } else if end <= now {
                    objects.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis),
                                                    value: value.rawValue, start: cursor, end: end))
                }
                cursor = end
                stage += 1
            }

            // Recovery readings, taken overnight / on waking.
            quantity(.restingHeartRate, Double(Int.random(in: 48...54, using: &rng)), perMinute, from: at(6, 30))
            quantity(.heartRateVariabilitySDNN, Double.random(in: 52...78, using: &rng),
                     .secondUnit(with: .milli), from: at(4, 30))
            quantity(.respiratoryRate, Double.random(in: 13.2...15.4, using: &rng), perMinute, from: at(3, 30))
            quantity(.oxygenSaturation, Double.random(in: 0.955...0.985, using: &rng), .percent(), from: at(3, 45))

            // Body: a weigh-in twice a week, drifting down slowly through the block.
            if daysAgo % 3 == 0 {
                let mass = 61.4 + Double(daysAgo) * 0.02 + Double.random(in: -0.3...0.3, using: &rng)
                let fat = 0.212 + Double.random(in: -0.004...0.004, using: &rng)
                quantity(.bodyMass, mass, .gramUnit(with: .kilo), from: at(7, 5))
                quantity(.bodyFatPercentage, fat, .percent(), from: at(7, 5))
                quantity(.leanBodyMass, mass * (1 - fat), .gramUnit(with: .kilo), from: at(7, 5))
            }
            if daysAgo % 7 == 2 {
                quantity(.vo2Max, 46.8 - Double(daysAgo) * 0.03 + Double.random(in: -0.2...0.2, using: &rng),
                         HKUnit(from: "ml/kg*min"), from: at(7, 40))
            }

            // Activity: steps through the waking day, resting energy in blocks.
            for hour in 8..<21 {
                quantity(.stepCount, Double(Int.random(in: 250...1100, using: &rng)), .count(),
                         from: at(hour), to: at(hour, 55))
            }
            for block in 0..<4 {
                quantity(.basalEnergyBurned, Double.random(in: 345...372, using: &rng), kcal,
                         from: at(block * 6), to: at(block * 6 + 5, 59))
            }

            // Nutrition: three meals and a snack. One day in ten goes unlogged.
            if Int.random(in: 0..<10, using: &rng) != 0 {
                let meals: [(hour: Int, share: Double)] = [(8, 0.24), (13, 0.34), (17, 0.10), (20, 0.32)]
                let energy = Double.random(in: 2250...2850, using: &rng)
                let protein = Double.random(in: 105...130, using: &rng)
                let fat = Double.random(in: 68...90, using: &rng)
                let fiber = Double.random(in: 24...34, using: &rng)
                let carbs = (energy - protein * 4 - fat * 9) / 4
                for meal in meals {
                    let time = at(meal.hour, 15)
                    quantity(.dietaryEnergyConsumed, energy * meal.share, kcal, from: time)
                    quantity(.dietaryProtein, protein * meal.share, gram, from: time)
                    quantity(.dietaryCarbohydrates, carbs * meal.share, gram, from: time)
                    quantity(.dietaryFatTotal, fat * meal.share, gram, from: time)
                    quantity(.dietaryFiber, fiber * meal.share, gram, from: time)
                }
            }
        }

        try await healthStore.save(objects)
        return objects.count
    }

    // MARK: - Sent tracking

    /// Same key WorkoutManager uses, so BackgroundSyncManager's auto-extract
    /// skips the seeded workouts instead of uploading them.
    private func markSent(_ ids: [UUID]) {
        let key = "sentWorkoutUUIDs"
        var sent = UserDefaults.standard.stringArray(forKey: key) ?? []
        sent.append(contentsOf: ids.map(\.uuidString).filter { !sent.contains($0) })
        UserDefaults.standard.set(sent, forKey: key)
    }

    // MARK: - Deletion

    /// Deletes every sample this app wrote to HealthKit (workouts, HR,
    /// distance, energy, routes). Real watch/phone data has a different
    /// source and is untouched.
    func deleteSeeded() async {
        isWorking = true
        statusMessage = "Deleting app-written HealthKit data…"
        defer { isWorking = false }

        do {
            try await healthStore.requestAuthorization(toShare: Self.shareTypes, read: [])
            let ownSource = HKQuery.predicateForObjects(from: HKSource.default())
            var total = 0
            for type in Self.shareTypes {
                total += try await deleteObjects(of: type, predicate: ownSource)
            }
            statusMessage = "Deleted \(total) app-written samples."
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func deleteObjects(of type: HKSampleType, predicate: NSPredicate) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            healthStore.deleteObjects(of: type, predicate: predicate) { _, count, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: count)
                }
            }
        }
    }
}

#endif
