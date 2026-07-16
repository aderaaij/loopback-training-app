//
//  WorkoutManager.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 14/03/2026.
//

import Foundation
import Combine
import HealthKit
import WorkoutKit

@MainActor
class WorkoutManager: ObservableObject {
    @Published var workouts: [WorkoutSummary] = []
    @Published var allWorkouts: [WorkoutSummary] = []
    @Published var extractionStatuses: [UUID: WorkoutExtractionStatus] = [:]
    @Published var activeFilter: HKWorkoutActivityType? = .running

    let extractor = WorkoutExtractor()
    let apiClient = WorkoutAPIClient()
    weak var scheduleManager: WorkoutScheduleManager?

    private let healthStore = HKHealthStore()
    private let sentKey = "sentWorkoutUUIDs"

    // MARK: - Configuration

    func configure(serverURL: String, apiKey: String) {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: normalizeURL(trimmed)) else {
            return
        }
        Task {
            await apiClient.configure(baseURL: url, apiKey: apiKey)
        }
    }

    private func normalizeURL(_ urlString: String) -> String {
        if urlString.hasPrefix("https://") || urlString.hasPrefix("http://") {
            return urlString
        }
        return "https://\(urlString)"
    }

    // MARK: - Fetch Workouts

    func fetchRecentWorkouts() {
        let workoutType = HKWorkoutType.workoutType()
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )

        // Combine date filter (6 months) with optional activity type filter
        let datePredicate = HKQuery.predicateForSamples(
            withStart: Calendar.current.date(byAdding: .month, value: -6, to: Date()),
            end: nil,
            options: .strictStartDate
        )
        let predicate: NSPredicate
        if let activityPredicate = activeFilter.map({ HKQuery.predicateForWorkouts(with: $0) }) {
            predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, activityPredicate])
        } else {
            predicate = datePredicate
        }

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sort]
        ) { [weak self] _, samples, _ in
            let summaries: [WorkoutSummary] = autoreleasepool {
                guard let hkWorkouts = samples as? [HKWorkout] else { return [] }
                let deduplicated = Self.deduplicateWorkouts(hkWorkouts)
                return deduplicated.map { workout in
                    WorkoutSummary(
                        id: workout.uuid,
                        activityType: Self.activityTypeName(workout.workoutActivityType),
                        activityName: Self.activityDisplayName(workout.workoutActivityType),
                        startDate: workout.startDate,
                        duration: workout.duration,
                        distance: workout.totalDistance?.doubleValue(for: .meter())
                    )
                }
            }

            Task { @MainActor [weak self] in
                self?.workouts = summaries
                for summary in summaries {
                    if self?.hasSentWorkout(summary.id) == true {
                        self?.extractionStatuses[summary.id] = .sent(Date())
                    }
                }
            }
        }

        healthStore.execute(query)
    }

    // MARK: - Fetch All Workouts (Unfiltered)

    /// Fetches recent workouts regardless of activity type filter.
    /// Used by the Training tab to show past workouts alongside scheduled plans.
    /// Limited to last 6 months and capped at 200 results.
    func fetchAllRecentWorkouts() {
        let workoutType = HKWorkoutType.workoutType()
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )
        let datePredicate = HKQuery.predicateForSamples(
            withStart: Calendar.current.date(byAdding: .month, value: -6, to: Date()),
            end: nil,
            options: .strictStartDate
        )

        let query = HKSampleQuery(
            sampleType: workoutType,
            predicate: datePredicate,
            limit: 200,
            sortDescriptors: [sort]
        ) { [weak self] _, samples, _ in
            let summaries: [WorkoutSummary] = autoreleasepool {
                guard let hkWorkouts = samples as? [HKWorkout] else { return [] }
                let deduplicated = Self.deduplicateWorkouts(hkWorkouts)
                return deduplicated.map { workout in
                    WorkoutSummary(
                        id: workout.uuid,
                        activityType: Self.activityTypeName(workout.workoutActivityType),
                        activityName: Self.activityDisplayName(workout.workoutActivityType),
                        startDate: workout.startDate,
                        duration: workout.duration,
                        distance: workout.totalDistance?.doubleValue(for: .meter())
                    )
                }
            }

            Task { @MainActor [weak self] in
                self?.allWorkouts = summaries
                for summary in summaries {
                    if self?.hasSentWorkout(summary.id) == true {
                        self?.extractionStatuses[summary.id] = .sent(Date())
                    }
                }
            }
        }

        healthStore.execute(query)
    }

    // MARK: - Extract & Send (Manual)

    func extractAndSend(workoutID: UUID) async {
        // Find the HKWorkout object
        guard let workout = await fetchHKWorkout(id: workoutID) else {
            extractionStatuses[workoutID] = .failed("Workout not found")
            return
        }

        extractionStatuses[workoutID] = .extracting

        // Try to match this workout to a scheduled plan workout
        let planId = findPlanWorkoutId(for: workout)

        do {
            // Encode inside autoreleasepool so route/HR arrays are freed
            // before moving on to the next workout.
            let jsonData: Data = try await {
                let detailed = try await extractor.extractWorkout(workout, planWorkoutId: planId)
                return try autoreleasepool {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    return try encoder.encode(detailed)
                }
            }()

            guard await apiClient.isConfigured else {
                extractionStatuses[workoutID] = .failed("Server not configured")
                return
            }

            extractionStatuses[workoutID] = .sending
            try await apiClient.send(data: jsonData)

            // If this HK workout fulfilled a prescribed plan workout, mark it completed.
            // Server stamps completed_at idempotently, so the inventory-sync safety net
            // won't clobber this accurate timestamp on a later call.
            if let planId {
                try? await apiClient.markPlanWorkoutCompleted(id: planId)
                // That may have been the plan's final queued run — the server
                // recomputes `finishable` on every read, so refresh and offer
                // the celebration while the achievement is fresh.
                await scheduleManager?.checkForFinishablePlan()
            }

            markAsSent(workoutID)
            extractionStatuses[workoutID] = .sent(Date())
        } catch {
            extractionStatuses[workoutID] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Plan Workout Matching

    /// Matches a HealthKit workout to a prescribed plan_workout (= workout_queue row)
    /// so `/api/workouts` is posted with a populated `plan_workout_id` FK.
    ///
    /// Matches against `scheduleManager.planWorkouts` (API objects) rather than the
    /// WorkoutKit `scheduledWorkouts` list — the old path filtered by
    /// `scheduled.complete == true`, which stopped flipping reliably after W1.
    ///
    /// Rule: same activity type + scheduled within ±6h of the HK start date.
    /// Exactly one match returns that id; zero or multiple return nil (freestyle /
    /// ambiguous). For legacy items where `scheduledDate` is nil, falls back to the
    /// iOS-side `scheduledDateMap`.
    private func findPlanWorkoutId(for workout: HKWorkout) -> UUID? {
        guard let scheduleManager else { return nil }

        let planWorkouts = scheduleManager.planWorkouts
        guard !planWorkouts.isEmpty else { return nil }

        let activityKey = Self.activityTypeName(workout.workoutActivityType)
        let sixHours: TimeInterval = 6 * 3600

        let candidates: [(UUID, TimeInterval)] = planWorkouts.compactMap { pw in
            guard pw.activityType == activityKey else { return nil }

            let date = pw.scheduledDate ?? scheduleManager.scheduledDate(for: pw.id)
            guard let date else { return nil }

            let timeDiff = abs(workout.startDate.timeIntervalSince(date))
            guard timeDiff <= sixHours else { return nil }

            return (pw.id, timeDiff)
        }

        // Exactly-one-match rule: ambiguity → leave null so the server doesn't get a wrong FK.
        guard candidates.count == 1 else { return nil }
        return candidates[0].0
    }

    // MARK: - Auto-Extract New Workouts

    /// Maximum number of workouts to extract concurrently.
    private static let maxConcurrentExtractions = 3

    func extractNewWorkouts() async {
        guard await apiClient.isConfigured else { return }

        // Fetch all workout types (not just the UI filter) so strength,
        // flexibility, etc. are also extracted and sent to the Training API.
        await fetchAllRecentWorkoutsAsync()

        // Filter to only unsent, non-in-progress workouts
        let pending = allWorkouts.filter { summary in
            !hasSentWorkout(summary.id) &&
            extractionStatuses[summary.id] != .extracting &&
            extractionStatuses[summary.id] != .sending
        }

        // Process concurrently in batches
        await extractInBatches(pending)
    }

    // MARK: - Re-sync All

    func resyncAll() async {
        // Clear sent tracking so every workout is treated as new
        UserDefaults.standard.removeObject(forKey: sentKey)
        extractionStatuses.removeAll()

        // Re-fetch the list, then extract & send each one
        await fetchRecentWorkoutsAsync()
        await extractInBatches(workouts)
    }

    // MARK: - Batch Extraction

    /// Processes workouts concurrently in groups of `maxConcurrentExtractions`.
    private func extractInBatches(_ summaries: [WorkoutSummary]) async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0

            for summary in summaries {
                if running >= Self.maxConcurrentExtractions {
                    await group.next()
                    running -= 1
                }

                running += 1
                group.addTask { [weak self] in
                    await self?.extractAndSend(workoutID: summary.id)
                }
            }

            await group.waitForAll()
        }
    }

    // MARK: - Async Fetch Wrapper

    /// Async wrapper around `fetchRecentWorkouts()` that waits for
    /// the HealthKit query to complete instead of using sleep.
    private func fetchRecentWorkoutsAsync() async {
        await withCheckedContinuation { continuation in
            let workoutType = HKWorkoutType.workoutType()
            let sort = NSSortDescriptor(
                key: HKSampleSortIdentifierStartDate, ascending: false
            )
            let datePredicate = HKQuery.predicateForSamples(
                withStart: Calendar.current.date(byAdding: .month, value: -6, to: Date()),
                end: nil,
                options: .strictStartDate
            )
            let predicate: NSPredicate
            if let activityPredicate = activeFilter.map({ HKQuery.predicateForWorkouts(with: $0) }) {
                predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [datePredicate, activityPredicate])
            } else {
                predicate = datePredicate
            }

            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { [weak self] _, samples, _ in
                let summaries: [WorkoutSummary] = autoreleasepool {
                    guard let hkWorkouts = samples as? [HKWorkout] else { return [] }
                    let deduplicated = Self.deduplicateWorkouts(hkWorkouts)
                    return deduplicated.map { workout in
                        WorkoutSummary(
                            id: workout.uuid,
                            activityType: Self.activityTypeName(workout.workoutActivityType),
                            activityName: Self.activityDisplayName(workout.workoutActivityType),
                            startDate: workout.startDate,
                            duration: workout.duration,
                            distance: workout.totalDistance?.doubleValue(for: .meter())
                        )
                    }
                }

                Task { @MainActor [weak self] in
                    self?.workouts = summaries
                    for summary in summaries {
                        if self?.hasSentWorkout(summary.id) == true {
                            self?.extractionStatuses[summary.id] = .sent(Date())
                        }
                    }
                    continuation.resume()
                }
            }

            healthStore.execute(query)
        }
    }

    /// Async wrapper around `fetchAllRecentWorkouts()` — fetches all workout types.
    private func fetchAllRecentWorkoutsAsync() async {
        await withCheckedContinuation { continuation in
            let workoutType = HKWorkoutType.workoutType()
            let sort = NSSortDescriptor(
                key: HKSampleSortIdentifierStartDate, ascending: false
            )
            let datePredicate = HKQuery.predicateForSamples(
                withStart: Calendar.current.date(byAdding: .month, value: -6, to: Date()),
                end: nil,
                options: .strictStartDate
            )

            let query = HKSampleQuery(
                sampleType: workoutType,
                predicate: datePredicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { [weak self] _, samples, _ in
                let summaries: [WorkoutSummary] = autoreleasepool {
                    guard let hkWorkouts = samples as? [HKWorkout] else { return [] }
                    let deduplicated = Self.deduplicateWorkouts(hkWorkouts)
                    return deduplicated.map { workout in
                        WorkoutSummary(
                            id: workout.uuid,
                            activityType: Self.activityTypeName(workout.workoutActivityType),
                            activityName: Self.activityDisplayName(workout.workoutActivityType),
                            startDate: workout.startDate,
                            duration: workout.duration,
                            distance: workout.totalDistance?.doubleValue(for: .meter())
                        )
                    }
                }

                Task { @MainActor [weak self] in
                    self?.allWorkouts = summaries
                    for summary in summaries {
                        if self?.hasSentWorkout(summary.id) == true {
                            self?.extractionStatuses[summary.id] = .sent(Date())
                        }
                    }
                    continuation.resume()
                }
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Sent Tracking

    func hasSentWorkout(_ id: UUID) -> Bool {
        let sent = UserDefaults.standard.stringArray(forKey: sentKey) ?? []
        return sent.contains(id.uuidString)
    }

    private func markAsSent(_ id: UUID) {
        var sent = UserDefaults.standard.stringArray(forKey: sentKey) ?? []
        if !sent.contains(id.uuidString) {
            sent.append(id.uuidString)
            UserDefaults.standard.set(sent, forKey: sentKey)
        }
    }

    // MARK: - Deduplication

    /// When multiple sources record the same workout session (e.g. Apple Watch +
    /// Strava), keep the one with the more specific activity type. Two workouts
    /// are considered duplicates when their time windows overlap by > 90%.
    nonisolated private static func deduplicateWorkouts(_ workouts: [HKWorkout]) -> [HKWorkout] {
        var keep: [HKWorkout] = []

        for workout in workouts {
            if let existingIdx = keep.firstIndex(where: { overlapFraction($0, workout) > 0.9 }) {
                // Prefer the one with a more specific activity type
                if workout.workoutActivityType != .other && keep[existingIdx].workoutActivityType == .other {
                    keep[existingIdx] = workout
                }
                // Otherwise keep the existing one (it's already more specific or equal)
            } else {
                keep.append(workout)
            }
        }

        return keep
    }

    /// Returns the fraction of overlap between two workouts' time intervals (0...1).
    nonisolated private static func overlapFraction(_ a: HKWorkout, _ b: HKWorkout) -> Double {
        let overlapStart = max(a.startDate, b.startDate)
        let overlapEnd = min(a.endDate, b.endDate)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        guard overlap > 0 else { return 0 }

        let shorter = min(
            a.endDate.timeIntervalSince(a.startDate),
            b.endDate.timeIntervalSince(b.startDate)
        )
        guard shorter > 0 else { return 0 }
        return overlap / shorter
    }

    // MARK: - Helpers

    private func fetchHKWorkout(id: UUID) async -> HKWorkout? {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForObject(with: id)
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: samples?.first as? HKWorkout)
            }
            healthStore.execute(query)
        }
    }

    /// Re-extract a full `DetailedWorkout` (route, HR/cadence/power series, splits,
    /// effort) from HealthKit for on-demand display. Returns `nil` if the workout
    /// can't be found or extraction fails.
    func getDetailedWorkout(for id: UUID) async -> DetailedWorkout? {
        guard let workout = await fetchHKWorkout(id: id) else { return nil }
        return try? await extractor.extractWorkout(workout)
    }

    nonisolated private static func activityTypeName(_ type: HKWorkoutActivityType) -> String {
        // Returns a machine-readable identifier for the JSON payload
        activityMap[type]?.0 ?? "other(\(type.rawValue))"
    }

    nonisolated private static func activityDisplayName(_ type: HKWorkoutActivityType) -> String {
        // Returns a human-readable name for the UI
        activityMap[type]?.1 ?? "Workout (\(type.rawValue))"
    }

    nonisolated private static let activityMap: [HKWorkoutActivityType: (String, String)] = [
        .running: ("running", "Run"),
        .walking: ("walking", "Walk"),
        .cycling: ("cycling", "Cycle"),
        .hiking: ("hiking", "Hike"),
        .swimming: ("swimming", "Swim"),
        .crossTraining: ("crossTraining", "Cross Training"),
        .functionalStrengthTraining: ("functionalStrength", "Strength"),
        .traditionalStrengthTraining: ("traditionalStrength", "Strength"),
        .yoga: ("yoga", "Yoga"),
        .pilates: ("pilates", "Pilates"),
        .elliptical: ("elliptical", "Elliptical"),
        .rowing: ("rowing", "Rowing"),
        .stairClimbing: ("stairClimbing", "Stair Climbing"),
        .highIntensityIntervalTraining: ("hiit", "HIIT"),
        .coreTraining: ("coreTraining", "Core"),
        .flexibility: ("flexibility", "Flexibility"),
        .cooldown: ("cooldown", "Cooldown"),
        .mixedCardio: ("mixedCardio", "Mixed Cardio"),
        .cardioDance: ("cardioDance", "Cardio Dance"),
        .mindAndBody: ("mindAndBody", "Mind & Body"),
        .play: ("play", "Play"),
        .other: ("other", "Other"),
        .socialDance: ("socialDance", "Social Dance"),
        .fitnessGaming: ("fitnessGaming", "Fitness Gaming"),
        .skatingSports: ("skating", "Skating"),
        .snowSports: ("snowSports", "Snow Sports"),
        .downhillSkiing: ("downhillSkiing", "Downhill Skiing"),
        .crossCountrySkiing: ("crossCountrySkiing", "XC Skiing"),
        .snowboarding: ("snowboarding", "Snowboarding"),
        .surfingSports: ("surfing", "Surfing"),
        .tennis: ("tennis", "Tennis"),
        .tableTennis: ("tableTennis", "Table Tennis"),
        .badminton: ("badminton", "Badminton"),
        .soccer: ("soccer", "Soccer"),
        .basketball: ("basketball", "Basketball"),
        .volleyball: ("volleyball", "Volleyball"),
        .golf: ("golf", "Golf"),
        .boxing: ("boxing", "Boxing"),
        .kickboxing: ("kickboxing", "Kickboxing"),
        .martialArts: ("martialArts", "Martial Arts"),
        .climbing: ("climbing", "Climbing"),
        .jumpRope: ("jumpRope", "Jump Rope"),
        .stairs: ("stairs", "Stairs"),
        .wheelchairWalkPace: ("wheelchairWalk", "Wheelchair Walk"),
        .wheelchairRunPace: ("wheelchairRun", "Wheelchair Run"),
    ]
}
