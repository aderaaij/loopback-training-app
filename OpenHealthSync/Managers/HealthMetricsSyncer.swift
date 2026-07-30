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
    /// Nutrition day rows per POST, same reasoning at day granularity.
    private let nutritionChunkSize = 400

    /// Share of a day's logged food entries that must actually carry a
    /// micronutrient before its daily sum is sent. Below this the sum is a
    /// partial subtotal masquerading as a total, so it's omitted instead.
    ///
    /// The exact figure is a judgement call, not a derived constant: 0.8 keeps
    /// a couple of unlabelled items from voiding an otherwise complete day
    /// while still rejecting the sparse case, where only a handful of entries
    /// in a day carry the field.
    private let microCoverageThreshold = 0.8

    /// Actor reentrancy guard: observer bursts overlap `syncMetrics` calls at
    /// its `await`s, and one in-flight sleep pass is always enough.
    private var sleepSyncInFlight = false

    /// Same guard for nutrition. A food-logging app writes every nutrient of a
    /// meal together, so one logged lunch fires the dietary observer several
    /// times — and a nutrition pass is seventeen HealthKit queries.
    private var nutritionSyncInFlight = false

    // MARK: - HealthKit Types

    static let readTypes: Set<HKObjectType> = Set<HKObjectType>([
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
    ]).union(dietaryReadTypes)

    /// Dietary types backing nutrition sync. Split out from `readTypes` only
    /// for readability — they're requested in the same single authorization
    /// call, which existing users see again on upgrade (the sheet lists just
    /// these new types). `requestAuthorization` runs on every launch for that
    /// reason; without it the new types stay unauthorized and every dietary
    /// query silently returns nothing.
    static let dietaryReadTypes: Set<HKObjectType> = [
        HKQuantityType(.dietaryEnergyConsumed),
        HKQuantityType(.dietaryCarbohydrates),
        HKQuantityType(.dietaryProtein),
        HKQuantityType(.dietaryFatTotal),
        HKQuantityType(.dietaryFatSaturated),
        HKQuantityType(.dietaryFiber),
        HKQuantityType(.dietarySugar),
        HKQuantityType(.dietarySodium),
        HKQuantityType(.dietaryPotassium),
        HKQuantityType(.dietaryCholesterol),
        HKQuantityType(.dietaryWater),
        HKQuantityType(.dietaryCaffeine),
        // Micros. Cheap to read and free to store (they ride in the payload's
        // open `micros` dictionary), but the key set must stay stable.
        HKQuantityType(.dietaryIron),
        HKQuantityType(.dietaryCalcium),
        HKQuantityType(.dietaryMagnesium),
        HKQuantityType(.dietaryVitaminC),
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
        // Captured before the quantity pass advances `lastSyncKey`, so
        // nutrition's window reaches back from the *previous* sync rather than
        // from this one.
        let nutritionStart = nutritionWindowStart(now)

        // The quantity error is held rather than thrown immediately: nutrition
        // ships on its own endpoint and must still run, exactly as sleep does
        // above. It's rethrown at the end so callers keep the old contract.
        var quantityError: Error?
        do {
            try await syncQuantityMetrics(now: now)
        } catch {
            quantityError = error
        }

        // Nutrition ships on its own endpoint; its errors are logged rather
        // than thrown so a food-logging hiccup can't starve the quantity
        // metrics.
        do {
            try await syncNutrition(from: nutritionStart, to: now)
        } catch {
            AppLog.health.error("Nutrition sync failed: \(String(describing: error), privacy: .public)")
        }

        if let quantityError { throw quantityError }
    }

    private func syncQuantityMetrics(now: Date) async throws {
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

    // MARK: - Nutrition
    //
    // Dietary intake ships to POST /api/nutrition as whole-day totals. Every
    // dietary quantity in HealthKit is cumulative, so each field is a
    // `fetchSumByDay` — the same query shape steps and active energy use.

    private func syncNutrition(from startDate: Date, to endDate: Date) async throws {
        guard !nutritionSyncInFlight else { return }
        nutritionSyncInFlight = true
        defer { nutritionSyncInFlight = false }

        let days = try await fetchNutritionDays(from: startDate, to: endDate)
        // Nothing logged in the window is a normal state, not an error — and
        // it's indistinguishable from denied dietary authorization, so it must
        // never be reported as a fact about what the athlete ate.
        guard !days.isEmpty else { return }

        try await uploadNutrition(days)
        AppLog.health.info("Synced \(days.count) days of nutrition")
    }

    /// Chunked day upsert. A rolling sync sends a handful of days and a
    /// 12-month backfill about 365, so the chunk only ever bites if
    /// `backfillMonths` grows a lot — it's here to bound the body, not because
    /// today's payloads are large.
    private func uploadNutrition(_ days: [DailyNutrition]) async throws {
        var index = 0
        while index < days.count {
            let chunk = Array(days[index ..< min(index + nutritionChunkSize, days.count)])
            try await apiClient.sendNutrition(NutritionBulkPayload(days: chunk))
            index += nutritionChunkSize
        }
    }

    /// Nutrition is logged retroactively — dinner entered next morning, a day
    /// corrected days later — so the window reaches back further than the
    /// metrics window's 1-day overlap. Statistics queries are cheap; a missed
    /// retroactive edit is permanent.
    ///
    /// The `startOfDay` is load-bearing, not hygiene: these are whole-day
    /// totals and the server upsert overwrites field-by-field, so a window edge
    /// landing mid-day would store that day's *tail* — the exact mechanism that
    /// corrupted July's sleep and steps.
    private func nutritionWindowStart(_ now: Date) -> Date {
        let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        let overlap = calendar.date(byAdding: .day, value: -7, to: lastSync ?? now) ?? now
        return calendar.startOfDay(for: overlap)
    }

    private func fetchNutritionDays(from startDate: Date, to endDate: Date) async throws -> [DailyNutrition] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = calendar.timeZone

        async let energyData = fetchSumByDay(.dietaryEnergyConsumed, unit: .kilocalorie(), from: startDate, to: endDate)
        async let carbsData = fetchSumByDay(.dietaryCarbohydrates, unit: .gram(), from: startDate, to: endDate)
        async let proteinData = fetchSumByDay(.dietaryProtein, unit: .gram(), from: startDate, to: endDate)
        async let fatData = fetchSumByDay(.dietaryFatTotal, unit: .gram(), from: startDate, to: endDate)
        async let satFatData = fetchSumByDay(.dietaryFatSaturated, unit: .gram(), from: startDate, to: endDate)
        async let fiberData = fetchSumByDay(.dietaryFiber, unit: .gram(), from: startDate, to: endDate)
        async let sugarData = fetchSumByDay(.dietarySugar, unit: .gram(), from: startDate, to: endDate)
        async let sodiumData = fetchSumByDay(.dietarySodium, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let potassiumData = fetchSumByDay(.dietaryPotassium, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let cholesterolData = fetchSumByDay(.dietaryCholesterol, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let waterData = fetchSumByDay(.dietaryWater, unit: .literUnit(with: .milli), from: startDate, to: endDate)
        async let caffeineData = fetchSumByDay(.dietaryCaffeine, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let ironData = fetchSumByDay(.dietaryIron, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let calciumData = fetchSumByDay(.dietaryCalcium, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let magnesiumData = fetchSumByDay(.dietaryMagnesium, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let vitaminCData = fetchSumByDay(.dietaryVitaminC, unit: .gramUnit(with: .milli), from: startDate, to: endDate)
        async let entryData = fetchDietaryEntries(from: startDate, to: endDate)
        // Coverage counts for the gate below: how many of a day's logged
        // entries actually carried each micronutrient.
        async let ironCountData = fetchSampleCountByDay(.dietaryIron, from: startDate, to: endDate)
        async let calciumCountData = fetchSampleCountByDay(.dietaryCalcium, from: startDate, to: endDate)
        async let magnesiumCountData = fetchSampleCountByDay(.dietaryMagnesium, from: startDate, to: endDate)
        async let vitaminCCountData = fetchSampleCountByDay(.dietaryVitaminC, from: startDate, to: endDate)

        let energy = (try? await energyData) ?? [:]
        let carbs = (try? await carbsData) ?? [:]
        let protein = (try? await proteinData) ?? [:]
        let fat = (try? await fatData) ?? [:]
        let satFat = (try? await satFatData) ?? [:]
        let fiber = (try? await fiberData) ?? [:]
        let sugar = (try? await sugarData) ?? [:]
        let sodium = (try? await sodiumData) ?? [:]
        let potassium = (try? await potassiumData) ?? [:]
        let cholesterol = (try? await cholesterolData) ?? [:]
        let water = (try? await waterData) ?? [:]
        let caffeine = (try? await caffeineData) ?? [:]
        let iron = (try? await ironData) ?? [:]
        let calcium = (try? await calciumData) ?? [:]
        let magnesium = (try? await magnesiumData) ?? [:]
        let vitaminC = (try? await vitaminCData) ?? [:]
        let entries = (try? await entryData) ?? (counts: [:], sources: [:])
        let ironCount = (try? await ironCountData) ?? [:]
        let calciumCount = (try? await calciumCountData) ?? [:]
        let magnesiumCount = (try? await magnesiumCountData) ?? [:]
        let vitaminCCount = (try? await vitaminCCountData) ?? [:]

        // Only days that actually carry a dietary sample get a row. Every date
        // here came from some dictionary's keys, so a row is never all-null.
        var allDates = Set<Date>()
        for dict in [energy, carbs, protein, fat, satFat, fiber, sugar, sodium,
                     potassium, cholesterol, water, caffeine,
                     iron, calcium, magnesium, vitaminC] {
            allDates.formUnion(dict.keys)
        }
        allDates.formUnion(entries.counts.keys)

        // How many micro readings were dropped as too sparse to mean anything,
        // logged once per pass so the gate's effect is visible rather than
        // silent.
        var suppressedMicros = 0

        /// True when enough of the day's logged entries carried the nutrient for
        /// its daily sum to be worth sending. See `microCoverageThreshold`.
        func isCovered(_ sampleCounts: [Date: Int], on dayStart: Date) -> Bool {
            // No entry count means coverage can't be computed at all, and an
            // unverifiable reading is treated exactly like a sparse one.
            guard let logged = entries.counts[dayStart], logged > 0,
                  let withNutrient = sampleCounts[dayStart] else { return false }
            return Double(withNutrient) / Double(logged) >= microCoverageThreshold
        }

        let days = allDates.sorted().map { dayStart in
            // A micronutrient sum over a sparse subset of entries is not a
            // daily total — food databases carry macros on nearly every entry
            // and micros on a fraction, and `cumulativeSum` faithfully adds up
            // only the few that had the field. Sending one anyway produced iron
            // at ~10% of any plausible intake, which reads to the coach as
            // severe deficiency. So a micro ships only when it's well covered;
            // otherwise it's omitted, which the server already reads as "not
            // tracked" rather than zero.
            //
            // This also means the field heals itself: a food logger with
            // complete nutrient data (Cronometer and similar pull from
            // USDA/NCCDB) clears the threshold on its own, and `sources`
            // records which app earned the trust.
            var micros: [String: Double] = [:]
            for (key, values, counts) in [
                ("iron_mg", iron, ironCount),
                ("calcium_mg", calcium, calciumCount),
                ("magnesium_mg", magnesium, magnesiumCount),
                ("vitamin_c_mg", vitaminC, vitaminCCount),
            ] {
                guard let value = values[dayStart] else { continue }
                if isCovered(counts, on: dayStart) {
                    micros[key] = value
                } else {
                    suppressedMicros += 1
                }
            }

            return DailyNutrition(
                date: dateFormatter.string(from: dayStart),
                energyKcal: energy[dayStart],
                carbsG: carbs[dayStart],
                proteinG: protein[dayStart],
                fatG: fat[dayStart],
                saturatedFatG: satFat[dayStart],
                fiberG: fiber[dayStart],
                sugarG: sugar[dayStart],
                sodiumMg: sodium[dayStart],
                potassiumMg: potassium[dayStart],
                cholesterolMg: cholesterol[dayStart],
                waterMl: water[dayStart],
                caffeineMg: caffeine[dayStart],
                micros: micros.isEmpty ? nil : micros,
                entryCount: entries.counts[dayStart],
                sources: entries.sources[dayStart],
                // Today's totals are always incomplete — the athlete hasn't
                // finished eating. The value is real, just partial; the flag
                // keeps it out of server-side averages until a later sync
                // re-sends the day complete.
                partial: calendar.isDateInToday(dayStart)
            )
        }

        if suppressedMicros > 0 {
            AppLog.health.info("Nutrition: omitted \(suppressedMicros) micronutrient reading(s) across \(days.count) day(s) — too few logged entries carried them to be a daily total")
        }
        return days
    }

    /// Entry count and writing apps per day, from one sample query over the
    /// whole window (not one per day). Dietary energy stands in for every
    /// nutrient: food-logging apps write a meal's nutrients together.
    private func fetchDietaryEntries(
        from startDate: Date,
        to endDate: Date
    ) async throws -> (counts: [Date: Int], sources: [Date: [String]]) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(.dietaryEnergyConsumed),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                var counts: [Date: Int] = [:]
                var sources: [Date: Set<String>] = [:]
                for sample in samples ?? [] {
                    let dayStart = self.calendar.startOfDay(for: sample.startDate)
                    counts[dayStart, default: 0] += 1
                    sources[dayStart, default: []].insert(sample.sourceRevision.source.name)
                }
                continuation.resume(returning: (counts, sources.mapValues { $0.sorted() }))
            }

            healthStore.execute(query)
        }
    }

    /// Number of samples per day for one dietary type. Paired with the dietary
    /// entry count, this measures what share of a day's logged food actually
    /// reported the nutrient — the difference between a daily total and a sum
    /// over whichever entries happened to carry the field.
    private func fetchSampleCountByDay(
        _ identifier: HKQuantityTypeIdentifier,
        from startDate: Date,
        to endDate: Date
    ) async throws -> [Date: Int] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKQuantityType(identifier),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var counts: [Date: Int] = [:]
                for sample in samples ?? [] {
                    counts[self.calendar.startOfDay(for: sample.startDate), default: 0] += 1
                }
                continuation.resume(returning: counts)
            }

            healthStore.execute(query)
        }
    }

    /// Most recent body-mass reading within the last 90 days. Read locally for
    /// the Trends screen's protein-per-kg figure — the app already holds
    /// body-mass authorization, so one number doesn't need a server round-trip.
    func latestBodyMassKg() async -> Double? {
        let end = Date()
        guard let start = calendar.date(byAdding: .day, value: -90, to: end) else { return nil }
        let byDay = (try? await fetchLatestByDay(
            .bodyMass, unit: .gramUnit(with: .kilo), from: start, to: end
        )) ?? [:]
        return byDay.max { $0.key < $1.key }?.value
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
    /// truncated steps/energy values the old delta window left behind. Finally
    /// it re-reads dietary intake over the same window, which is how a fresh
    /// install gets intake history at all: the rolling sync only reaches back a
    /// week, so anything older would otherwise never be uploaded. It also
    /// clears any day left stuck at `partial: true` by a sync gap wider than
    /// the rolling window.
    ///
    /// Settings exposes a manual trigger for re-runs.
    @discardableResult
    func backfillHealthHistory() async throws -> HealthHistoryBackfillResult {
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

        // Nutrition is isolated even here, where a human is watching: sleep and
        // metrics have already landed by this point, so letting a nutrition
        // failure throw would report the whole repair as failed. A server
        // without the endpoint yet is exactly that case.
        var nutritionDays: Int?
        do {
            let days = try await fetchNutritionDays(from: start, to: end)
            if !days.isEmpty {
                try await uploadNutrition(days)
            }
            nutritionDays = days.count
        } catch {
            AppLog.health.error("History backfill: nutrition failed: \(String(describing: error), privacy: .public)")
        }

        UserDefaults.standard.set(true, forKey: backfillDoneKey)
        AppLog.health.info("History backfill: sent \(samples.count) sleep samples (server stored \(result.stored) across \(result.daysUpdated) day(s)), \(metrics.count) days of metrics, and \(nutritionDays.map(String.init) ?? "no") days of nutrition")
        return HealthHistoryBackfillResult(
            sleepSamplesStored: result.stored,
            daysUpdated: result.daysUpdated,
            metricDays: metrics.count,
            nutritionDays: nutritionDays
        )
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

// MARK: - Backfill result

/// What one run of `backfillHealthHistory()` actually landed, so Settings can
/// report it instead of guessing. `nonisolated` because it crosses from the
/// syncer actor to the main actor (types default to @MainActor here).
///
/// `nutritionDays` is nil when the nutrition leg failed — distinct from 0,
/// which means it succeeded and there was simply nothing logged.
nonisolated struct HealthHistoryBackfillResult: Sendable {
    let sleepSamplesStored: Int
    let daysUpdated: Int
    let metricDays: Int
    let nutritionDays: Int?
}

// MARK: - HKUnit helpers

private extension HKUnit {
    static func beatsPerMinute() -> HKUnit {
        .count().unitDivided(by: .minute())
    }
}
