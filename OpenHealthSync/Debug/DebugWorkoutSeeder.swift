//
//  DebugWorkoutSeeder.swift
//  OpenHealthSync
//
//  DEBUG-only HealthKit seeder for the simulator: writes ~6 months of
//  realistic runs (distance, energy, heart-rate series, GPS route around
//  Lisbon) plus weekly strength sessions, so the workout list, detail charts,
//  and splits all have data without a real watch.
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

    private static let shareTypes: Set<HKSampleType> = [
        HKWorkoutType.workoutType(),
        heartRateType,
        distanceType,
        energyType,
        HKSeriesType.workoutRoute(),
    ]

    // Praça do Comércio-ish riverside start point.
    private static let startCoordinate = CLLocationCoordinate2D(latitude: 38.7075, longitude: -9.1364)

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
                    if let id = try await seedRun(start: start, km: km, kind: run.kind, rng: &rng) {
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
            statusMessage = "Seeded \(seededIDs.count) workouts\(markAsSynced ? " (marked as synced)" : "")."
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
    /// out-and-back route along the Tejo.
    private func seedRun(start: Date, km: Double, kind: RunKind,
                         rng: inout SeededGenerator) async throws -> UUID? {
        let paceSecPerKm = Double.random(in: 315...400, using: &rng)   // 5:15–6:40 /km
        let duration = km * paceSecPerKm
        let end = start.addingTimeInterval(duration)
        let speed = km * 1000 / duration                               // m/s

        let config = HKWorkoutConfiguration()
        config.activityType = .running
        config.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: healthStore, configuration: config, device: .local())
        try await builder.beginCollection(at: start)

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
                start: start.addingTimeInterval(t),
                end: start.addingTimeInterval(sliceEnd)
            ))
            samples.append(HKQuantitySample(
                type: Self.energyType,
                quantity: HKQuantity(unit: .kilocalorie(), doubleValue: sliceKcal),
                start: start.addingTimeInterval(t),
                end: start.addingTimeInterval(sliceEnd)
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
                cooldownTo: 135, rng: &rng
            ))
        case .long:
            samples.append(contentsOf: heartRateSamples(
                start: start, duration: duration, warmupFrom: 108, steady: 144, rng: &rng
            ))
        case .easy:
            samples.append(contentsOf: heartRateSamples(
                start: start, duration: duration, warmupFrom: 108, steady: 141, rng: &rng
            ))
        }

        try await builder.addSamples(samples)
        try await builder.endCollection(at: end)
        guard let workout = try await builder.finishWorkout() else { return nil }

        // Out-and-back route: east along the river, then retrace.
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: nil)
        try await routeBuilder.insertRouteData(routeLocations(
            start: start, duration: duration, speed: speed, rng: &rng
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
                                rng: inout SeededGenerator) -> [CLLocation] {
        let interval: TimeInterval = 15
        let halfway = duration / 2
        let metersPerDegreeLat = 111_111.0
        let metersPerDegreeLon = metersPerDegreeLat * cos(Self.startCoordinate.latitude * .pi / 180)

        var locations: [CLLocation] = []
        var t: TimeInterval = 0
        while t <= duration {
            // Distance from start along the out-and-back line.
            let along = t <= halfway ? speed * t : speed * (duration - t)
            let wiggle = sin(t / 40) * 25 + Double.random(in: -6...6, using: &rng)
            locations.append(CLLocation(
                coordinate: CLLocationCoordinate2D(
                    latitude: Self.startCoordinate.latitude + wiggle / metersPerDegreeLat,
                    longitude: Self.startCoordinate.longitude + along / metersPerDegreeLon
                ),
                altitude: 8,
                horizontalAccuracy: 5,
                verticalAccuracy: 8,
                timestamp: start.addingTimeInterval(t)
            ))
            t += interval
        }
        return locations
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
