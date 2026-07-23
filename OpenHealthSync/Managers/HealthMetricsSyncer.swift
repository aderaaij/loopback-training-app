//
//  HealthMetricsSyncer.swift
//  OpenHealthSync
//
//  Created by Claude on 04/04/2026.
//

import Foundation
import HealthKit
import os

actor HealthMetricsSyncer {
    private let healthStore = HKHealthStore()
    private let apiClient: WorkoutAPIClient

    private let lastSyncKey = "healthMetricsLastSyncDate"
    private let sleepAnchorKey = "sleepSamplesAnchor"
    private let backfillDoneKey = "healthHistoryBackfillDone"
    private let calendar = Calendar.current

    /// How far the one-shot history backfill reaches. A year comfortably
    /// covers the corrupted period and gives the server a real baseline.
    private let backfillMonths = 12
    /// Samples per POST, to keep request bodies modest on flaky mobile links.
    private let uploadChunkSize = 2000

    /// Actor reentrancy guard: observer bursts overlap `syncMetrics` calls at
    /// its `await`s, and one in-flight sleep pass is always enough.
    private var sleepSyncInFlight = false

    // MARK: - HealthKit Types

    static let readTypes: Set<HKObjectType> = [
        HKCategoryType(.sleepAnalysis),
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.bodyMass),
        HKQuantityType(.vo2Max),
        HKQuantityType(.stepCount),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.bodyFatPercentage),
        HKQuantityType(.leanBodyMass),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.oxygenSaturation),
        // Workout effort (RPE 1–10) — read here so authorization is granted
        // alongside other metrics; consumed by WorkoutExtractor, not this syncer.
        HKQuantityType(.workoutEffortScore),
        HKQuantityType(.estimatedWorkoutEffortScore),
        // Workout detail — needed by WorkoutExtractor for the rich detail view
        // (GPS route + per-km splits) and in-workout heart rate. Requested here
        // so route access is granted via the app's primary auth path, not only
        // through the optional Open Wearables tiers.
        HKObjectType.workoutType(),
        HKSeriesType.workoutRoute(),
        HKQuantityType(.heartRate),
        // Date of birth — read during onboarding to seed one age observation
        // note for the coach. Characteristic; no share access needed.
        HKCharacteristicType(.dateOfBirth),
    ]

    init(apiClient: WorkoutAPIClient) {
        self.apiClient = apiClient
    }

    // MARK: - Authorization

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
            return true
        } catch {
            AppLog.health.error("HealthKit authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: - Characteristics

    /// The user's date of birth, if readable. Characteristic authorization
    /// can't be queried, so we just attempt the read (after requesting auth)
    /// and return nil on denial/absence. Used once during onboarding.
    func dateOfBirthComponents() -> DateComponents? {
        try? healthStore.dateOfBirthComponents()
    }

    // MARK: - Sync

    func syncMetrics() async throws {
        // Sleep ships as raw samples on its own anchored path; its errors are
        // logged rather than thrown so a sleep hiccup can't starve the
        // quantity metrics below, and vice versa.
        do {
            try await syncSleepSamples()
        } catch {
            AppLog.health.error("Sleep sample sync failed: \(String(describing: error), privacy: .public)")
        }

        let now = Date()
        let startDate: Date

        if let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
            // Overlap by 1 day for upsert safety. The window must open on a
            // local midnight: these are whole-day totals and the server
            // upsert overwrites whole fields, so a window edge landing
            // mid-day truncates every re-sent day to its tail — the July
            // sleep/steps corruption.
            let overlapped = calendar.date(byAdding: .day, value: -1, to: lastSync) ?? lastSync
            startDate = calendar.startOfDay(for: overlapped)
        } else {
            // First sync: last 7 days
            startDate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -7, to: now) ?? now)
        }

        let metrics = try await fetchMetrics(from: startDate, to: now)
        guard !metrics.isEmpty else { return }

        let payload = HealthMetricsBulkPayload(metrics: metrics)
        try await apiClient.sendHealthMetrics(payload)

        UserDefaults.standard.set(now, forKey: lastSyncKey)
        AppLog.health.info("Synced \(metrics.count) days of health metrics")
    }

    // MARK: - Fetch All Metrics

    private func fetchMetrics(from startDate: Date, to endDate: Date) async throws -> [DailyHealthMetrics] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = calendar.timeZone

        // Fetch all metric types concurrently. Sleep is absent by design:
        // it goes to the server as raw samples (see syncSleepSamples), never
        // as an app-computed daily total.
        async let restingHRData = fetchAverageByDay(.restingHeartRate, unit: .beatsPerMinute(), from: startDate, to: endDate)
        async let hrvData = fetchAverageByDay(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: startDate, to: endDate)
        async let weightData = fetchLatestByDay(.bodyMass, unit: .gramUnit(with: .kilo), from: startDate, to: endDate)
        async let vo2Data = fetchAverageByDay(.vo2Max, unit: HKUnit(from: "ml/kg*min"), from: startDate, to: endDate)
        async let stepsData = fetchSumByDay(.stepCount, unit: .count(), from: startDate, to: endDate)
        async let energyData = fetchSumByDay(.activeEnergyBurned, unit: .kilocalorie(), from: startDate, to: endDate)
        async let bodyFatData = fetchLatestByDay(.bodyFatPercentage, unit: .percent(), from: startDate, to: endDate)
        async let leanMassData = fetchLatestByDay(.leanBodyMass, unit: .gramUnit(with: .kilo), from: startDate, to: endDate)
        async let respRateData = fetchAverageByDay(.respiratoryRate, unit: .beatsPerMinute(), from: startDate, to: endDate)
        async let spo2Data = fetchAverageByDay(.oxygenSaturation, unit: .percent(), from: startDate, to: endDate)

        let restingHR = (try? await restingHRData) ?? [:]
        let hrv = (try? await hrvData) ?? [:]
        let weight = (try? await weightData) ?? [:]
        let vo2 = (try? await vo2Data) ?? [:]
        let steps = (try? await stepsData) ?? [:]
        let energy = (try? await energyData) ?? [:]
        let bodyFat = (try? await bodyFatData) ?? [:]
        let leanMass = (try? await leanMassData) ?? [:]
        let respRate = (try? await respRateData) ?? [:]
        let spo2 = (try? await spo2Data) ?? [:]

        // Collect all dates that have any data
        var allDates = Set<Date>()
        for dict in [restingHR, hrv, weight, vo2, steps, energy, bodyFat, leanMass, respRate, spo2] {
            allDates.formUnion(dict.keys)
        }

        return allDates.sorted().compactMap { dayStart in
            let dateString = dateFormatter.string(from: dayStart)

            // Skip days with no data at all
            let hasAnyMetric = restingHR[dayStart] != nil || hrv[dayStart] != nil ||
                weight[dayStart] != nil || vo2[dayStart] != nil ||
                steps[dayStart] != nil || energy[dayStart] != nil ||
                bodyFat[dayStart] != nil || leanMass[dayStart] != nil ||
                respRate[dayStart] != nil || spo2[dayStart] != nil

            guard hasAnyMetric else { return nil }

            // Convert body fat and SpO2 from 0-1 to 0-100
            let bodyFatPct = bodyFat[dayStart].map { $0 * 100 }
            let spo2Pct = spo2[dayStart].map { $0 * 100 }

            return DailyHealthMetrics(
                date: dateString,
                restingHeartRate: restingHR[dayStart],
                hrvSdnn: hrv[dayStart],
                weight: weight[dayStart],
                vo2Max: vo2[dayStart],
                steps: steps[dayStart].map { Int($0) },
                activeEnergyBurned: energy[dayStart],
                bodyFatPercentage: bodyFatPct,
                leanBodyMass: leanMass[dayStart],
                respiratoryRate: respRate[dayStart],
                spo2: spo2Pct
            )
        }
    }

    // MARK: - Sum by Day (steps, active energy)

    private func fetchSumByDay(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [Date: Double] {
        let quantityType = HKQuantityType(identifier)
        let interval = DateComponents(day: 1)
        let anchorDate = calendar.startOfDay(for: startDate)

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var dayValues: [Date: Double] = [:]
                results?.enumerateStatistics(from: startDate, to: endDate) { stats, _ in
                    if let sum = stats.sumQuantity() {
                        let dayStart = self.calendar.startOfDay(for: stats.startDate)
                        dayValues[dayStart] = sum.doubleValue(for: unit)
                    }
                }
                continuation.resume(returning: dayValues)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Average by Day (resting HR, HRV, VO2Max, respiratory rate, SpO2)

    private func fetchAverageByDay(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [Date: Double] {
        let quantityType = HKQuantityType(identifier)
        let interval = DateComponents(day: 1)
        let anchorDate = calendar.startOfDay(for: startDate)

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage,
                anchorDate: anchorDate,
                intervalComponents: interval
            )

            query.initialResultsHandler = { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var dayValues: [Date: Double] = [:]
                results?.enumerateStatistics(from: startDate, to: endDate) { stats, _ in
                    if let avg = stats.averageQuantity() {
                        let dayStart = self.calendar.startOfDay(for: stats.startDate)
                        dayValues[dayStart] = avg.doubleValue(for: unit)
                    }
                }
                continuation.resume(returning: dayValues)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Latest by Day (weight, body fat, lean mass)

    private func fetchLatestByDay(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [Date: Double] {
        let quantityType = HKQuantityType(identifier)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var dayValues: [Date: Double] = [:]
                for sample in (samples as? [HKQuantitySample]) ?? [] {
                    let dayStart = self.calendar.startOfDay(for: sample.startDate)
                    // Keep the latest sample per day (overwrites earlier ones)
                    dayValues[dayStart] = sample.quantity.doubleValue(for: unit)
                }
                continuation.resume(returning: dayValues)
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Sleep Samples (raw)
    //
    // Sleep is never aggregated on-device. Raw samples — every stage,
    // including `unspecified` and `in_bed` — go to POST /api/health/sleep/samples;
    // the server merges overlaps (sweep-line, one winner per slice) and
    // attributes nights noon-to-noon, so merge logic can iterate without app
    // releases.

    private func syncSleepSamples() async throws {
        guard !sleepSyncInFlight else { return }
        sleepSyncInFlight = true
        defer { sleepSyncInFlight = false }

        // One-shot history push, retried on every sync trigger until it lands.
        // Idempotent server-side, so a half-finished attempt costs nothing.
        if !UserDefaults.standard.bool(forKey: backfillDoneKey) {
            try await backfillHealthHistory()
        }

        // The anchored query resumes from HealthKit's change log, so samples
        // a watch delivers hours late still reach the server no matter which
        // night they belong to. First run bounds the dump to recent nights;
        // deep history arrives via the backfill above.
        let anchor = storedSleepAnchor()
        let predicate: NSPredicate? = anchor == nil
            ? HKQuery.predicateForSamples(
                withStart: calendar.date(byAdding: .day, value: -14, to: Date()),
                end: nil
            )
            : nil

        let (samples, anchorData) = try await fetchNewSleepSamples(predicate: predicate, anchor: anchor)
        if !samples.isEmpty {
            let result = try await uploadSleepSamples(samples)
            AppLog.health.info("Sleep samples: sent \(samples.count), server stored \(result.stored) across \(result.daysUpdated) day(s)")
        }
        // Persist the anchor only after every chunk landed — a failed upload
        // throws above, and the next sync re-reads from the old anchor (the
        // server skips re-sent samples).
        if let anchorData {
            UserDefaults.standard.set(anchorData, forKey: sleepAnchorKey)
        }
    }

    /// History repair, safe to run repeatedly: re-posts the last
    /// `backfillMonths` of raw sleep samples (the server stores each once),
    /// then recomputes the quantity metrics over the same window as whole-day
    /// totals and lets the server overwrite — which heals the tail-of-day
    /// truncated steps/energy values the old delta window left behind.
    /// Settings exposes a manual trigger for re-runs.
    @discardableResult
    func backfillHealthHistory() async throws -> (stored: Int, daysUpdated: Int) {
        let end = Date()
        let start = calendar.startOfDay(
            for: calendar.date(byAdding: .month, value: -backfillMonths, to: end) ?? end
        )

        let samples = try await fetchSleepSampleHistory(from: start, to: end)
        let result = try await uploadSleepSamples(samples)

        let metrics = try await fetchMetrics(from: start, to: end)
        if !metrics.isEmpty {
            try await apiClient.sendHealthMetrics(HealthMetricsBulkPayload(metrics: metrics))
        }

        UserDefaults.standard.set(true, forKey: backfillDoneKey)
        AppLog.health.info("History backfill: sent \(samples.count) sleep samples (server stored \(result.stored) across \(result.daysUpdated) day(s)) and \(metrics.count) days of metrics")
        return result
    }

    private func uploadSleepSamples(_ samples: [SleepSamplePayload]) async throws -> (stored: Int, daysUpdated: Int) {
        var stored = 0
        var daysUpdated = Set<String>()
        let timezone = TimeZone.current.identifier
        var index = 0
        while index < samples.count {
            let chunk = Array(samples[index ..< min(index + uploadChunkSize, samples.count)])
            let response = try await apiClient.sendSleepSamples(
                SleepSamplesUploadPayload(timezone: timezone, samples: chunk)
            )
            stored += response.stored
            daysUpdated.formUnion(response.daysUpdated)
            index += uploadChunkSize
        }
        return (stored, daysUpdated.count)
    }

    private func fetchSleepSampleHistory(from startDate: Date, to endDate: Date) async throws -> [SleepSamplePayload] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKCategoryType(.sleepAnalysis),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let payloads = ((samples as? [HKCategorySample]) ?? []).compactMap(Self.sleepPayload)
                continuation.resume(returning: payloads)
            }

            healthStore.execute(query)
        }
    }

    /// Returns new-since-anchor samples plus the fresh anchor, already
    /// serialized: `Data` is what gets persisted, and it crosses back into
    /// the actor without `Sendable` friction.
    private func fetchNewSleepSamples(
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?
    ) async throws -> (samples: [SleepSamplePayload], anchorData: Data?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKCategoryType(.sleepAnalysis),
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let payloads = ((samples as? [HKCategorySample]) ?? []).compactMap(Self.sleepPayload)
                let anchorData = newAnchor.flatMap {
                    try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
                }
                continuation.resume(returning: (payloads, anchorData))
            }

            healthStore.execute(query)
        }
    }

    private func storedSleepAnchor() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: sleepAnchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private nonisolated static func sleepPayload(from sample: HKCategorySample) -> SleepSamplePayload? {
        // The server 422s a whole chunk when any sample has end <= start, so
        // degenerate zero-duration samples must never reach a payload.
        guard sample.endDate > sample.startDate else { return nil }
        let stage: String
        switch sample.value {
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: stage = "rem"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: stage = "core"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: stage = "deep"
        case HKCategoryValueSleepAnalysis.awake.rawValue: stage = "awake"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: stage = "unspecified"
        case HKCategoryValueSleepAnalysis.inBed.rawValue: stage = "in_bed"
        default: return nil
        }
        return SleepSamplePayload(
            start: sample.startDate,
            end: sample.endDate,
            stage: stage,
            source: sample.sourceRevision.source.bundleIdentifier
        )
    }
}

// MARK: - HKUnit helpers

private extension HKUnit {
    static func beatsPerMinute() -> HKUnit {
        .count().unitDivided(by: .minute())
    }
}
