//
//  WorkoutManager.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 14/03/2026.
//

import Foundation
import Observation
import HealthKit
import WorkoutKit

@MainActor
@Observable
class WorkoutManager {
    var workouts: [WorkoutSummary] = []
    var allWorkouts: [WorkoutSummary] = []
    var extractionStatuses: [UUID: WorkoutExtractionStatus] = [:]
    var activeFilter: HKWorkoutActivityType? = .running

    let extractor = WorkoutExtractor()
    let apiClient = WorkoutAPIClient()
    weak var scheduleManager: WorkoutScheduleManager?

    private let healthStore = HKHealthStore()
    private let sentKey = "sentWorkoutUUIDs"
    /// Workouts sent soon after they ended, by id, with the end date. The
    /// watch hands the heart rate of the minutes after a workout, the VO2 max
    /// estimate and the effort rating to the phone late, so such a workout is
    /// sent once more when they have had time to arrive.
    private let awaitingLateFiguresKey = "workoutsAwaitingLateFigures"
    /// How long after a workout's end its late figures can be counted on.
    private static let lateFiguresSettleTime: TimeInterval = 15 * 60

    // MARK: - Configuration

    func configure(serverURL: String, alternativeURL: String? = nil, apiKey: String) {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: normalizeURL(trimmed)) else {
            return
        }
        Task {
            await apiClient.configure(
                baseURL: url,
                alternativeURL: alternativeURL.flatMap { URL(string: $0) },
                apiKey: apiKey
            )
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

        // Combine the history window with the optional activity type filter
        let datePredicate = HKQuery.predicateForSamples(
            withStart: WorkoutHistoryWindow.current.startDate(),
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
                self?.markSentStatuses(for: summaries)
            }
        }

        healthStore.execute(query)
    }

    // MARK: - Fetch All Workouts (Unfiltered)

    /// Fetches recent workouts regardless of activity type filter.
    /// Used by the Training tab to show past workouts alongside scheduled plans.
    /// Covers the history window chosen in Settings → Sync.
    func fetchAllRecentWorkouts() {
        let workoutType = HKWorkoutType.workoutType()
        let sort = NSSortDescriptor(
            key: HKSampleSortIdentifierStartDate, ascending: false
        )
        let datePredicate = HKQuery.predicateForSamples(
            withStart: WorkoutHistoryWindow.current.startDate(),
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
                self?.markSentStatuses(for: summaries)
            }
        }

        healthStore.execute(query)
    }

    // MARK: - Latest Run

    /// The most recent run in Health, whatever the history window: for an
    /// answer given outside the app's screens, where no list has been loaded.
    /// Nil when there is none; throws when Health can't be read, as on a
    /// locked phone.
    func latestRun() async throws -> WorkoutSummary? {
        try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            // A few, not one: the same run can be in Health twice, from two
            // sources, and the list shows only the one deduplication keeps.
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: HKQuery.predicateForWorkouts(with: .running),
                limit: 5,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let latest = Self.deduplicateWorkouts(samples as? [HKWorkout] ?? []).first
                continuation.resume(returning: latest.map { workout in
                    WorkoutSummary(
                        id: workout.uuid,
                        activityType: Self.activityTypeName(workout.workoutActivityType),
                        activityName: Self.activityDisplayName(workout.workoutActivityType),
                        startDate: workout.startDate,
                        duration: workout.duration,
                        distance: workout.totalDistance?.doubleValue(for: .meter())
                    )
                })
            }
            healthStore.execute(query)
        }
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
        let planId = await findPlanWorkoutId(for: workout)

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
            let stored = try await apiClient.send(data: jsonData)

            // If this HK workout fulfilled a prescribed plan workout, mark it completed.
            // Server stamps completed_at idempotently, so the inventory-sync safety net
            // won't clobber this accurate timestamp on a later call.
            // Go by the link the server kept: on a re-send it ignores our match
            // for a workout the athlete linked or unlinked by hand.
            if let planId = stored.map(\.planWorkoutId) ?? planId {
                try? await apiClient.markPlanWorkoutCompleted(id: planId)
                // That may have been the plan's final queued run — the server
                // recomputes `finishable` on every read, so refresh and offer
                // the celebration while the achievement is fresh.
                await scheduleManager?.checkForFinishablePlan()
            }

            markAsSent(workoutID)
            noteLateFigures(for: workout)
            extractionStatuses[workoutID] = .sent(Date())
        } catch {
            extractionStatuses[workoutID] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Plan Workout Matching

    /// Matches a HealthKit workout to a prescribed plan_workout (= workout_queue row)
    /// so `/api/workouts` is posted with a populated `plan_workout_id` FK.
    ///
    /// Three steps, the first that answers wins:
    ///
    /// 1. A session the server already counts this workout for is kept. A
    ///    re-send carries the match again, and the server writes whatever it
    ///    carries, so re-deriving it could drop or swap a link once the
    ///    schedule has moved on. An automatic match never replaces a link.
    /// 2. The session the watch ticked off with this workout, when it was
    ///    started from the watch's schedule. That says which session it was
    ///    whatever day it was planned for, so it comes before the planned
    ///    time: a run done a day early often lands in another run's slot.
    ///    The tick can reach the phone after the workout does, and
    ///    WorkoutKit's `complete` has not always flipped reliably; until it
    ///    has, this step has nothing to say and the next one decides.
    ///    `workoutsTickedOffSinceSent` picks the workout up again when the
    ///    tick arrives after it went out unmatched.
    /// 3. The planned time, for a run recorded any other way. Matches against
    ///    `scheduleManager.planWorkouts` (API objects): same activity type +
    ///    scheduled within ±6h of the HK start date. Exactly one match
    ///    returns that id; zero or multiple return nil (freestyle /
    ///    ambiguous). For legacy items where `scheduledDate` is nil, falls
    ///    back to the iOS-side `scheduledDateMap`.
    private func findPlanWorkoutId(for workout: HKWorkout) async -> UUID? {
        guard let scheduleManager else { return nil }

        await scheduleManager.ensureSessionLinks()
        if let kept = scheduleManager.sessionCounted(for: workout.uuid) {
            return kept
        }

        let activityKey = Self.activityTypeName(workout.workoutActivityType)
        let sixHours: TimeInterval = 6 * 3600

        let this = WatchCompletionLog.Candidate(
            id: workout.uuid,
            activity: activityKey,
            span: DateInterval(start: workout.startDate, end: workout.endDate)
        )
        if let session = WatchCompletionLog.session(
            for: this,
            ticked: await tickedSessions(scheduleManager).map(\.ticked),
            others: uncountedWorkouts(scheduleManager)
        ) {
            scheduleManager.noteWorkoutOffered(forSession: session)
            return session
        }

        let planWorkouts = scheduleManager.planWorkouts
        guard !planWorkouts.isEmpty else { return nil }

        let candidates: [(UUID, TimeInterval)] = planWorkouts.compactMap { pw in
            guard pw.activityType == activityKey else { return nil }
            // A run the athlete skipped isn't the one they just did, and
            // leaving it in makes the exactly-one rule below give up: moving a
            // run onto an occupied day and skipping what was there puts two
            // runs on the same hour by design.
            guard pw.status != "skipped" else { return nil }

            let date = pw.scheduledDate ?? scheduleManager.scheduledDate(for: pw.id)
            guard let date else { return nil }

            let timeDiff = abs(workout.startDate.timeIntervalSince(date))
            guard timeDiff <= sixHours else { return nil }

            // A session that has its workout from some other time, done
            // early or late or counted by hand, is settled. A run that
            // happens to fall in its old slot isn't a second go at it.
            if let counted = scheduleManager.linkedWorkoutId(forSession: pw.id),
               let other = allWorkouts.first(where: { $0.id == counted }),
               abs(other.startDate.timeIntervalSince(date)) > sixHours {
                return nil
            }

            return (pw.id, timeDiff)
        }

        // Exactly-one-match rule: ambiguity → leave null so the server doesn't get a wrong FK.
        guard candidates.count == 1 else { return nil }
        return candidates[0].0
    }

    // MARK: - Sessions Ticked Off on the Watch

    /// The ticked sessions that await a workout, in the terms the matching
    /// works in, and whether a workout was put forward for each before.
    private func tickedSessions(
        _ scheduleManager: WorkoutScheduleManager
    ) async -> [(ticked: WatchCompletionLog.Ticked, wasOffered: Bool)] {
        await scheduleManager.tickedSessionsAwaitingWorkout().map {
            (
                WatchCompletionLog.Ticked(
                    session: $0.id,
                    activity: Self.activityTypeName($0.activity),
                    window: $0.window
                ),
                $0.wasOffered
            )
        }
    }

    /// Recent workouts that no session counts yet: the ones a ticked session
    /// can have been done with. The summaries carry no end date; start plus
    /// duration falls short of it by the pauses, which is close enough here.
    private func uncountedWorkouts(_ scheduleManager: WorkoutScheduleManager) -> [WatchCompletionLog.Candidate] {
        let counted = scheduleManager.countedWorkoutIds
        return allWorkouts
            .filter { !counted.contains($0.id) }
            .map {
                WatchCompletionLog.Candidate(
                    id: $0.id,
                    activity: $0.activityType,
                    span: DateInterval(start: $0.startDate, duration: $0.duration)
                )
            }
    }

    /// Workouts that were sent before the watch's tick for their session
    /// reached the phone, and so went out unmatched. Sending them once more
    /// lets `findPlanWorkoutId` link them to the session the watch ran. A
    /// session asks once: if the athlete unlinks the two afterwards, asking
    /// again on every pass would keep re-sending the workout for nothing.
    private func workoutsTickedOffSinceSent() async -> Set<UUID> {
        guard let scheduleManager else { return [] }
        await scheduleManager.ensureSessionLinks()

        let sessions = await tickedSessions(scheduleManager).filter { !$0.wasOffered }.map(\.ticked)
        guard !sessions.isEmpty else { return [] }

        let workouts = uncountedWorkouts(scheduleManager)
        let sent = sentWorkoutIDs()
        var late: Set<UUID> = []
        for session in sessions {
            guard let workout = WatchCompletionLog.workout(for: session, among: workouts),
                  sent.contains(workout.uuidString)
            else { continue }
            scheduleManager.noteWorkoutOffered(forSession: session.session)
            late.insert(workout)
        }
        return late
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
        let sent = sentWorkoutIDs()
        let pending = allWorkouts.filter { summary in
            !sent.contains(summary.id.uuidString) &&
            extractionStatuses[summary.id] != .extracting &&
            extractionStatuses[summary.id] != .sending
        }

        // Plus the ones sent before their late figures could have arrived,
        // or before the watch's tick for their session had.
        let due = workoutsDueForResend()
        let tickedLate = await workoutsTickedOffSinceSent()
        let resend = allWorkouts.filter { summary in
            (due.contains(summary.id.uuidString) || tickedLate.contains(summary.id)) &&
            !pending.contains { $0.id == summary.id } &&
            extractionStatuses[summary.id] != .extracting &&
            extractionStatuses[summary.id] != .sending
        }

        // Process concurrently in batches
        await extractInBatches(pending + resend)
    }

    // MARK: - Late Figures

    /// After a successful send: remember the workout if it ended too recently
    /// for everything to be in Health, forget it otherwise.
    private func noteLateFigures(for workout: HKWorkout) {
        var awaiting = UserDefaults.standard.dictionary(forKey: awaitingLateFiguresKey) as? [String: Double] ?? [:]
        if Date() < workout.endDate.addingTimeInterval(Self.lateFiguresSettleTime) {
            awaiting[workout.uuid.uuidString] = workout.endDate.timeIntervalSince1970
        } else {
            awaiting[workout.uuid.uuidString] = nil
        }
        UserDefaults.standard.set(awaiting, forKey: awaitingLateFiguresKey)
    }

    /// Ids of remembered workouts whose late figures should be in by now.
    /// Entries too old to still be in any history window are dropped.
    private func workoutsDueForResend() -> Set<String> {
        var awaiting = UserDefaults.standard.dictionary(forKey: awaitingLateFiguresKey) as? [String: Double] ?? [:]
        guard !awaiting.isEmpty else { return [] }
        let now = Date().timeIntervalSince1970
        let stale = awaiting.filter { now - $0.value > 30 * 24 * 3600 }.keys
        if !stale.isEmpty {
            stale.forEach { awaiting[$0] = nil }
            UserDefaults.standard.set(awaiting, forKey: awaitingLateFiguresKey)
        }
        return Set(awaiting.filter { now - $0.value >= Self.lateFiguresSettleTime }.keys)
    }

    // MARK: - Re-sync All

    func resyncAll() async {
        // Clear sent tracking so every workout is treated as new
        UserDefaults.standard.removeObject(forKey: sentKey)
        UserDefaults.standard.removeObject(forKey: awaitingLateFiguresKey)
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
                withStart: WorkoutHistoryWindow.current.startDate(),
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
                    self?.markSentStatuses(for: summaries)
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
                withStart: WorkoutHistoryWindow.current.startDate(),
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
                    self?.markSentStatuses(for: summaries)
                    continuation.resume()
                }
            }

            healthStore.execute(query)
        }
    }

    // MARK: - Sent Tracking

    /// Every id marked as sent. Read once per pass: with a long history
    /// window, asking UserDefaults per workout re-reads the whole list each
    /// time.
    private func sentWorkoutIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])
    }

    private func markSentStatuses(for summaries: [WorkoutSummary]) {
        let sent = sentWorkoutIDs()
        for summary in summaries where sent.contains(summary.id.uuidString) {
            extractionStatuses[summary.id] = .sent(Date())
        }
    }

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
            // Callers pass workouts newest first, so anything kept that
            // starts at or after this one's end cannot overlap it, and
            // neither can whatever was kept before that. Stopping there
            // keeps this linear when the history window is years long.
            var existingIdx: Int?
            for idx in keep.indices.reversed() {
                if keep[idx].startDate >= workout.endDate { break }
                if overlapFraction(keep[idx], workout) > 0.9 {
                    existingIdx = idx
                    break
                }
            }
            if let existingIdx {
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
