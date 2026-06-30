//
//  HealthMetricsSyncer.swift
//  OpenHealthSync
//
//  Created by Claude on 04/04/2026.
//

import Foundation
import HealthKit

actor HealthMetricsSyncer {
    private let healthStore = HKHealthStore()
    private let apiClient: WorkoutAPIClient

    private let lastSyncKey = "healthMetricsLastSyncDate"
    private let calendar = Calendar.current

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
            print("[HealthMetricsSyncer] Authorization failed: \(error)")
            return false
        }
    }

    // MARK: - Sync

    func syncMetrics() async throws {
        let now = Date()
        let startDate: Date

        if let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date {
            // Overlap by 1 day for upsert safety
            startDate = calendar.date(byAdding: .day, value: -1, to: lastSync) ?? lastSync
        } else {
            // First sync: last 7 days
            startDate = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        }

        let metrics = try await fetchMetrics(from: startDate, to: now)
        guard !metrics.isEmpty else { return }

        let payload = HealthMetricsBulkPayload(metrics: metrics)
        try await apiClient.sendHealthMetrics(payload)

        UserDefaults.standard.set(now, forKey: lastSyncKey)
        print("[HealthMetricsSyncer] Synced \(metrics.count) days of health metrics")
    }

    // MARK: - Fetch All Metrics

    private func fetchMetrics(from startDate: Date, to endDate: Date) async throws -> [DailyHealthMetrics] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = calendar.timeZone

        // Fetch all metric types concurrently
        async let sleepData = fetchSleepByDay(from: startDate, to: endDate)
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

        let sleep = (try? await sleepData) ?? [:]
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
        var allDates = Set<Date>(sleep.keys)
        for dict in [restingHR, hrv, weight, vo2, steps, energy, bodyFat, leanMass, respRate, spo2] {
            allDates.formUnion(dict.keys)
        }

        return allDates.sorted().compactMap { dayStart in
            let dateString = dateFormatter.string(from: dayStart)

            // Skip days with no data at all
            let hasSleep = sleep[dayStart] != nil
            let hasAnyMetric = restingHR[dayStart] != nil || hrv[dayStart] != nil ||
                weight[dayStart] != nil || vo2[dayStart] != nil ||
                steps[dayStart] != nil || energy[dayStart] != nil ||
                bodyFat[dayStart] != nil || leanMass[dayStart] != nil ||
                respRate[dayStart] != nil || spo2[dayStart] != nil

            guard hasSleep || hasAnyMetric else { return nil }

            // Convert body fat and SpO2 from 0-1 to 0-100
            let bodyFatPct = bodyFat[dayStart].map { $0 * 100 }
            let spo2Pct = spo2[dayStart].map { $0 * 100 }

            return DailyHealthMetrics(
                date: dateString,
                sleepDuration: sleep[dayStart]?.duration,
                sleepStages: sleep[dayStart]?.stages,
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

    // MARK: - Sleep Analysis

    private struct SleepDay {
        var duration: Double = 0     // total non-awake seconds
        var stages: SleepStages?
    }

    private func fetchSleepByDay(
        from startDate: Date,
        to endDate: Date
    ) async throws -> [Date: SleepDay] {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var dayData: [Date: (awake: Double, rem: Double, core: Double, deep: Double)] = [:]

                for sample in (samples as? [HKCategorySample]) ?? [] {
                    let duration = sample.endDate.timeIntervalSince(sample.startDate)
                    // Attribute sleep to the day the sleep session started
                    let dayStart = self.calendar.startOfDay(for: sample.startDate)

                    var entry = dayData[dayStart] ?? (0, 0, 0, 0)

                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        entry.rem += duration
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                        entry.core += duration
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        entry.deep += duration
                    case HKCategoryValueSleepAnalysis.awake.rawValue:
                        entry.awake += duration
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        // Older data without stage breakdown — count as core
                        entry.core += duration
                    default:
                        break
                    }

                    dayData[dayStart] = entry
                }

                var result: [Date: SleepDay] = [:]
                for (day, stages) in dayData {
                    let totalSleep = stages.rem + stages.core + stages.deep
                    result[day] = SleepDay(
                        duration: totalSleep,
                        stages: SleepStages(
                            awake: stages.awake > 0 ? stages.awake : nil,
                            rem: stages.rem > 0 ? stages.rem : nil,
                            core: stages.core > 0 ? stages.core : nil,
                            deep: stages.deep > 0 ? stages.deep : nil
                        )
                    )
                }
                continuation.resume(returning: result)
            }

            healthStore.execute(query)
        }
    }
}

// MARK: - HKUnit helpers

private extension HKUnit {
    static func beatsPerMinute() -> HKUnit {
        .count().unitDivided(by: .minute())
    }
}
