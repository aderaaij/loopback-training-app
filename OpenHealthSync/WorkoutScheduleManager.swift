//
//  WorkoutScheduleManager.swift
//  OpenHealthSync
//
//  Fetches queued workout compositions from the training API,
//  builds WorkoutKit CustomWorkout objects, and schedules them
//  on Apple Watch via WorkoutScheduler.
//

import Foundation
import Combine
import SwiftUI
import SwiftData
import UIKit
import WorkoutKit
import HealthKit

enum RefreshState: Equatable {
    case idle
    case syncing(step: SyncStep)
    case scheduling(current: Int, total: Int)
    case done(count: Int)
    case failed(message: String)
}

enum SyncStep: Int, Equatable, CaseIterable {
    case inventory = 0
    case actions = 1
    case fetching = 2

    var label: String {
        switch self {
        case .inventory: return "Syncing inventory…"
        case .actions: return "Processing changes…"
        case .fetching: return "Checking for workouts…"
        }
    }

    var progress: Double {
        Double(rawValue + 1) / Double(SyncStep.allCases.count + 1)
    }
}

@MainActor
class WorkoutScheduleManager: ObservableObject {
    @Published var scheduledWorkouts: [ScheduledWorkoutPlan] = []
    @Published var refreshState: RefreshState = .idle
    @Published var authorizationState: WorkoutScheduler.AuthorizationState = .notDetermined
    @Published var activePlan: TrainingPlan?
    /// The active strength cycle, if any — display-only (Hevy routine markers),
    /// never scheduled to the watch. Can coexist with an active running plan.
    @Published var activeStrengthPlan: TrainingPlan?
    @Published var planWorkouts: [PlanWorkout] = []
    @Published var isLoadingPlan = true
    @Published var allPlans: [TrainingPlan] = []
    @Published var isLoadingPlans = false
    /// Merged run + strength agenda from /api/schedule/calendar.
    @Published var calendarEntries: [CalendarEntry] = []
    /// The plan the celebration sheet is showing (nil = no sheet). Set by a
    /// banner tap or by the post-sync auto-check.
    @Published var celebrationPlan: TrainingPlan?
    /// Every active plan from the last fetch. `activePlan`/`activeStrengthPlan`
    /// keep one per activity type for the hero cards, but finishable detection
    /// must scan all of them: the coach creates follow-up blocks as `active`
    /// before they start, so a wrapped plan and its successor coexist.
    @Published private(set) var activePlans: [TrainingPlan] = []

    /// Plans whose auto-presented celebration was dismissed this session.
    /// The banner keeps showing (the server's `finishable` flag persists until
    /// someone completes the plan) — this only stops the sheet re-popping
    /// uninvited.
    private var celebrationSnoozedIds: Set<UUID> = []

    private let apiClient: WorkoutAPIClient
    /// Posts the "you finished {plan}" local notification when a plan turns
    /// finishable during a background wake. Set once at app init.
    weak var notificationManager: NotificationManager?

    /// Maps workout plan UUIDs to the DateComponents they were scheduled at.
    /// Needed by WorkoutScheduler.remove(_:at:) to identify which workout to remove.
    private var scheduledDateMap: [UUID: DateComponents] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "scheduledDateMap"),
                  let decoded = try? JSONDecoder().decode([String: CodableDateComponents].self, from: data)
            else { return [:] }
            return decoded.reduce(into: [:]) { result, pair in
                guard let uuid = UUID(uuidString: pair.key) else { return }
                result[uuid] = pair.value.dateComponents
            }
        }
        set {
            let encodable = newValue.reduce(into: [String: CodableDateComponents]()) { result, pair in
                result[pair.key.uuidString] = CodableDateComponents(pair.value)
            }
            if let data = try? JSONEncoder().encode(encodable) {
                UserDefaults.standard.set(data, forKey: "scheduledDateMap")
            }
        }
    }

    init(apiClient: WorkoutAPIClient) {
        self.apiClient = apiClient
    }

    /// Fallback source of truth for plan workouts whose API-supplied `scheduled_date`
    /// is null (pre ~2026-03-18 legacy queue items). Reads the locally-persisted
    /// DateComponents written at schedule time.
    func scheduledDate(for id: UUID) -> Date? {
        guard let components = scheduledDateMap[id] else { return nil }
        return Calendar.current.date(from: components)
    }

    // MARK: - Authorization

    func requestAuthorization() async {
        let state = await WorkoutScheduler.shared.requestAuthorization()
        authorizationState = state
    }

    // MARK: - Load Scheduled Workouts

    func loadScheduledWorkouts() async {
        let current = await WorkoutScheduler.shared.scheduledWorkouts
        scheduledWorkouts = current

        // Backfill the date map for any workouts not yet tracked (e.g. legacy workouts
        // scheduled before the date map existed).
        var map = scheduledDateMap
        var didChange = false
        for scheduled in current {
            if map[scheduled.plan.id] == nil {
                map[scheduled.plan.id] = scheduled.date
                didChange = true
            }
        }
        if didChange {
            scheduledDateMap = map
        }
    }

    // MARK: - Active Plan

    func loadActivePlan() async {
        isLoadingPlan = true
        defer { isLoadingPlan = false }
        do {
            // A running plan and a strength cycle can both be active.
            let plans = try await apiClient.fetchActivePlans()
            activePlans = plans
            let plan = plans.first { !$0.isStrength }
            activePlan = plan
            activeStrengthPlan = plans.first { $0.isStrength }

            if let plan {
                planWorkouts = try await apiClient.fetchPlanWorkouts(planId: plan.id)
            } else {
                planWorkouts = []
            }
        } catch {
            print("Failed to load active plan: \(error)")
        }

        await loadScheduleCalendar()
    }

    // MARK: - Plan Completion (celebration flow)

    /// First active plan the server says is ready to wrap up — drives the
    /// celebration banner on the training tab. Scans every active plan, not
    /// just the hero-card ones: the finishable plan is often shadowed by its
    /// already-active successor block.
    var finishablePlan: TrainingPlan? {
        activePlans.first { $0.isFinishable }
    }

    /// Banner tap: always presents, even if the auto-check was snoozed.
    func presentCelebration(for plan: TrainingPlan) {
        celebrationPlan = plan
    }

    /// Called when the celebration sheet is dismissed without completing, so
    /// the auto-check doesn't immediately re-present it this session.
    func snoozeCelebration(for planId: UUID) {
        celebrationSnoozedIds.insert(planId)
    }

    /// Refreshes the active plans and auto-presents the celebration when one
    /// is finishable — e.g. right after syncing the workout that completed the
    /// plan's final queued run, or a plan whose window quietly lapsed.
    func checkForFinishablePlan() async {
        await loadActivePlan()
        guard let plan = finishablePlan else { return }

        // Woken in the background (HealthKit delivered the final run while
        // the app was closed): the sheet can't present, so announce with a
        // local notification. Tapping it opens the app, which lands in the
        // auto-present below on the next check.
        if UIApplication.shared.applicationState != .active {
            await notificationManager?.notifyPlanFinishable(plan)
        }

        guard celebrationPlan == nil,
              !celebrationSnoozedIds.contains(plan.id) else { return }
        celebrationPlan = plan
    }

    /// Completes a plan on the server (optionally with rating/feedback) and
    /// refreshes every plan surface. Returns the already-active follow-up plan
    /// of the same activity type, or nil when nothing is lined up.
    func completePlan(_ plan: TrainingPlan, feedback: String?, rating: Int?) async throws -> TrainingPlan? {
        let response = try await apiClient.completePlan(id: plan.id, feedback: feedback, rating: rating)
        celebrationSnoozedIds.insert(plan.id)
        notificationManager?.clearPlanFinishableNotification(planId: plan.id)
        await loadActivePlan()
        if !allPlans.isEmpty {
            await loadAllPlans()
        }
        return response.nextPlan
    }

    // MARK: - Unified Schedule Calendar

    private static let calendarDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Refreshes the merged run + strength agenda: two weeks back (so
    /// completed strength sessions keep their ✓ on the timeline) through
    /// eight weeks ahead.
    func loadScheduleCalendar() async {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let from = calendar.date(byAdding: .day, value: -14, to: today),
              let to = calendar.date(byAdding: .day, value: 56, to: today) else { return }

        do {
            let response = try await apiClient.fetchScheduleCalendar(
                from: Self.calendarDayFormatter.string(from: from),
                to: Self.calendarDayFormatter.string(from: to)
            )
            calendarEntries = response.entries
        } catch {
            // Best-effort: keep whatever agenda we already have.
            print("Failed to load schedule calendar: \(error)")
        }
    }

    /// Fetches a plan's expanded cadence (dated sessions + conflict warnings)
    /// on demand for the plan detail screen.
    func schedule(forPlan planId: UUID) async -> PlanScheduleResponse? {
        do {
            return try await apiClient.fetchPlanSchedule(planId: planId)
        } catch {
            print("Failed to load schedule for plan \(planId): \(error)")
            return nil
        }
    }

    /// Loads every plan so the plans browser can group them into
    /// upcoming / current / archived.
    func loadAllPlans() async {
        isLoadingPlans = true
        defer { isLoadingPlans = false }
        do {
            allPlans = try await apiClient.fetchAllPlans()
        } catch {
            print("Failed to load plans: \(error)")
        }
    }

    /// Fetches the workouts for a specific plan on demand (used by the plan
    /// detail view for plans other than the active one).
    func workouts(forPlan planId: UUID) async -> [PlanWorkout] {
        do {
            return try await apiClient.fetchPlanWorkouts(planId: planId)
        } catch {
            print("Failed to load workouts for plan \(planId): \(error)")
            return []
        }
    }

    // MARK: - Sync Workout Inventory to Server

    /// Reports all locally-scheduled workout IDs to the server so the LLM can
    /// target them for edit/delete actions, even if they predate the queue system.
    func syncWorkoutInventory() async {
        let workouts = await WorkoutScheduler.shared.scheduledWorkouts
        let inventory = workouts.map { scheduled -> WorkoutInventoryItem in
            let name: String
            switch scheduled.plan.workout {
            case .custom(let custom):
                name = custom.displayName ?? "Custom Workout"
            case .goal(let goal):
                name = "Goal: \(goal.activity.displayName)"
            case .pacer(let pacer):
                name = "Pacer: \(pacer.activity.displayName)"
            case .swimBikeRun:
                name = "Swim-Bike-Run"
            @unknown default:
                name = "Workout"
            }
            return WorkoutInventoryItem(
                id: scheduled.plan.id,
                displayName: name,
                date: scheduled.date,
                complete: scheduled.complete
            )
        }

        do {
            try await apiClient.syncInventory(inventory)

            // Safety net: mark any locally-complete workouts as completed server-side.
            // The primary completion signal is per-ingest in WorkoutManager.extractAndSend;
            // the server stamps completed_at idempotently so this double-write is safe.
            for item in inventory where item.complete {
                try? await apiClient.markPlanWorkoutCompleted(id: item.id)
            }
        } catch {
            print("Failed to sync workout inventory: \(error)")
        }
    }

    // MARK: - Auto Sync

    /// Lightweight check for pending queue items and actions.
    /// Runs the full refresh silently if there's work to do.
    func autoSync(modelContext: ModelContext? = nil) async {
        // Don't auto-sync if a manual refresh is in progress
        switch refreshState {
        case .idle, .done:
            break
        default:
            return
        }

        do {
            let queue = try await apiClient.fetchQueue()
            let actions = try await apiClient.fetchPendingActions()

            if !queue.isEmpty || !actions.isEmpty {
                print("[AutoSync] Found \(queue.count) queued workouts, \(actions.count) pending actions")
                await refreshFromServer(modelContext: modelContext)
                await loadActivePlan()
            } else {
                // Still sync inventory to report completion status
                await syncWorkoutInventory()
                // Keep the merged agenda fresh (strength sessions can be
                // added or completed without any queue work existing).
                await loadScheduleCalendar()
            }
        } catch {
            // Silent failure — auto-sync is best-effort
            print("[AutoSync] Check failed: \(error)")
        }
    }

    // MARK: - Refresh from Server

    func refreshFromServer(modelContext: ModelContext? = nil) async {
        // Sync any unsynced feedback entries first
        if let modelContext {
            await syncUnsyncedFeedback(modelContext: modelContext)
        }

        refreshState = .syncing(step: .inventory)
        await syncWorkoutInventory()

        refreshState = .syncing(step: .actions)
        await syncEditsAndDeletes()

        refreshState = .syncing(step: .fetching)
        do {
            let queue = try await apiClient.fetchQueue()

            if queue.isEmpty {
                refreshState = .done(count: 0)
                return
            }

            var scheduled = 0
            for (index, composition) in queue.enumerated() {
                refreshState = .scheduling(current: index + 1, total: queue.count)

                do {
                    let customWorkout = try buildCustomWorkout(from: composition)
                    let plan = WorkoutPlan(.custom(customWorkout), id: composition.id)

                    let dateComponents = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: composition.scheduledDate
                    )

                    await WorkoutScheduler.shared.schedule(plan, at: dateComponents)
                    scheduledDateMap[composition.id] = dateComponents
                    try await apiClient.updateQueueItemStatus(id: composition.id, status: "synced")
                    scheduled += 1
                } catch {
                    print("Failed to schedule '\(composition.displayName)': \(error)")
                }
            }

            await loadScheduledWorkouts()
            refreshState = .done(count: scheduled)

        } catch {
            refreshState = .failed(message: error.localizedDescription)
        }
    }

    // MARK: - Remove All

    func removeAll() async {
        await WorkoutScheduler.shared.removeAllWorkouts()
        scheduledDateMap = [:]
        await loadScheduledWorkouts()
    }

    // MARK: - Remove Single Workout

    func removeWorkout(id: UUID) async -> Bool {
        guard let dateComponents = scheduledDateMap[id] else {
            print("No stored date for workout \(id), cannot remove")
            return false
        }

        // Find the matching plan in the scheduler
        let allScheduled = await WorkoutScheduler.shared.scheduledWorkouts
        guard let match = allScheduled.first(where: { $0.plan.id == id }) else {
            print("Workout \(id) not found in scheduler")
            scheduledDateMap.removeValue(forKey: id)
            return false
        }

        await WorkoutScheduler.shared.remove(match.plan, at: dateComponents)
        scheduledDateMap.removeValue(forKey: id)
        await loadScheduledWorkouts()
        return true
    }

    // MARK: - Reschedule Workout (same workout, new date)

    /// Moves a workout to a new date without changing its content.
    /// Used by the missed workout feedback flow when the user taps "Reschedule".
    func rescheduleWorkout(id: UUID, to newDate: Date) async -> Bool {
        // Find the existing plan in the scheduler
        let allScheduled = await WorkoutScheduler.shared.scheduledWorkouts
        guard let match = allScheduled.first(where: { $0.plan.id == id }) else {
            print("Workout \(id) not found in scheduler for reschedule")
            return false
        }

        // Remove from old date
        let removed = await removeWorkout(id: id)
        if !removed {
            print("Could not remove workout \(id) from old date for reschedule")
        }

        // Schedule at new date
        let newDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: newDate
        )

        await WorkoutScheduler.shared.schedule(match.plan, at: newDateComponents)
        scheduledDateMap[id] = newDateComponents
        await loadScheduledWorkouts()
        return true
    }

    // MARK: - Sync Feedback to Server

    /// Fire-and-forget upload of feedback to the training API.
    /// Marks the SwiftData entry as synced on success.
    func syncFeedback(_ payload: WorkoutFeedbackPayload, feedbackId: UUID, modelContext: ModelContext) {
        Task {
            do {
                try await apiClient.submitFeedback(payload)
                markFeedbackSynced(id: feedbackId, modelContext: modelContext)
            } catch {
                print("Feedback sync failed (will retry on next sync): \(error.localizedDescription)")
            }
        }
    }

    /// Retry uploading any feedback entries that haven't been synced yet.
    /// Called during the refresh flow to catch entries that failed on first attempt.
    func syncUnsyncedFeedback(modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<WorkoutFeedback>(
            predicate: #Predicate<WorkoutFeedback> { $0.synced == false }
        )
        guard let unsynced = try? modelContext.fetch(descriptor), !unsynced.isEmpty else {
            return
        }

        for feedback in unsynced {
            let payload = WorkoutFeedbackPayload(
                id: feedback.id,
                workoutId: feedback.workoutId,
                workoutName: feedback.workoutName,
                scheduledDate: feedback.scheduledDate,
                detectedAt: feedback.detectedAt,
                acknowledgedAt: feedback.acknowledgedAt,
                reason: feedback.reason.rawValue,
                reasonNote: feedback.reasonNote,
                action: feedback.action.rawValue,
                newDate: feedback.newDate,
                dismissed: feedback.dismissed
            )
            do {
                try await apiClient.submitFeedback(payload)
                feedback.synced = true
            } catch {
                print("Retry sync failed for feedback \(feedback.id): \(error.localizedDescription)")
            }
        }

        try? modelContext.save()
    }

    private func markFeedbackSynced(id: UUID, modelContext: ModelContext) {
        let descriptor = FetchDescriptor<WorkoutFeedback>(
            predicate: #Predicate<WorkoutFeedback> { $0.id == id }
        )
        if let feedback = try? modelContext.fetch(descriptor).first {
            feedback.synced = true
            try? modelContext.save()
        }
    }

    // MARK: - Edit Workout (remove + re-schedule)

    func editWorkout(id: UUID, composition: QueuedWorkoutComposition) async -> Bool {
        // Remove the old version
        let removed = await removeWorkout(id: id)
        if !removed {
            print("Could not remove old workout \(id) for edit")
        }

        // Schedule the updated version
        do {
            let customWorkout = try buildCustomWorkout(from: composition)
            let plan = WorkoutPlan(.custom(customWorkout), id: composition.id)

            let dateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: composition.scheduledDate
            )

            await WorkoutScheduler.shared.schedule(plan, at: dateComponents)
            scheduledDateMap[composition.id] = dateComponents
            await loadScheduledWorkouts()
            return true
        } catch {
            print("Failed to schedule edited workout: \(error)")
            return false
        }
    }

    // MARK: - Sync Edits and Deletes from Server

    func syncEditsAndDeletes() async {
        do {
            let actions = try await apiClient.fetchPendingActions()

            for action in actions {
                switch action.action {
                case "delete":
                    let success = await removeWorkout(id: action.workoutId)
                    if success {
                        try? await apiClient.acknowledgePendingAction(id: action.id)
                    }

                case "edit":
                    guard let composition = action.composition else {
                        print("Edit action \(action.id) missing composition")
                        continue
                    }
                    let success = await editWorkout(id: action.workoutId, composition: composition)
                    if success {
                        try? await apiClient.acknowledgePendingAction(id: action.id)
                    }

                default:
                    print("Unknown action type: \(action.action)")
                }
            }
        } catch {
            print("Failed to sync edits/deletes: \(error)")
        }
    }

    // MARK: - Build CustomWorkout

    func buildCustomWorkout(from composition: QueuedWorkoutComposition) throws -> CustomWorkout {
        let activity = mapActivityType(composition.activityType)
        let location = mapLocation(composition.location)

        let warmup: WorkoutStep? = composition.warmup.map { step in
            WorkoutStep(goal: mapGoal(step.goal), alert: mapAlert(step.alert))
        }

        let blocks: [IntervalBlock] = composition.blocks.map { block in
            let steps: [IntervalStep] = block.steps.map { step in
                IntervalStep(
                    mapPurpose(step.purpose),
                    goal: mapGoal(step.goal),
                    alert: mapAlert(step.alert)
                )
            }
            return IntervalBlock(steps: steps, iterations: block.iterations)
        }

        let cooldown: WorkoutStep? = composition.cooldown.map { step in
            WorkoutStep(goal: mapGoal(step.goal), alert: mapAlert(step.alert))
        }

        return CustomWorkout(
            activity: activity,
            location: location,
            displayName: composition.displayName,
            warmup: warmup,
            blocks: blocks,
            cooldown: cooldown
        )
    }

    // MARK: - Mapping Helpers

    private func mapGoal(_ goal: CompositionGoal) -> WorkoutGoal {
        switch goal.type {
        case "distance":
            guard let value = goal.value else { return .open }
            let unit = mapLengthUnit(goal.unit)
            return .distance(value, unit)
        case "time":
            guard let value = goal.value else { return .open }
            let unit = mapDurationUnit(goal.unit)
            return .time(value, unit)
        case "energy":
            guard let value = goal.value else { return .open }
            let unit = mapEnergyUnit(goal.unit)
            return .energy(value, unit)
        default:
            return .open
        }
    }

    private func mapAlert(_ alert: CompositionAlert?) -> (any WorkoutAlert)? {
        guard let alert else { return nil }

        switch alert.type {
        case "speed":
            guard let min = alert.min, let max = alert.max else { return nil }
            let unit = mapSpeedUnit(alert.unit)
            return SpeedRangeAlert(
                target: Measurement(value: min, unit: unit)...Measurement(value: max, unit: unit),
                metric: .current
            )
        case "heartRate":
            guard let min = alert.min, let max = alert.max else { return nil }
            return HeartRateRangeAlert.heartRate(min...max)
        case "heartRateZone":
            guard let zone = alert.zone else { return nil }
            return HeartRateZoneAlert(zone: zone)
        case "cadence":
            guard let min = alert.min, let max = alert.max else { return nil }
            return CadenceRangeAlert.cadence(min...max)
        case "power":
            guard let min = alert.min, let max = alert.max else { return nil }
            return PowerRangeAlert.power(min...max, unit: .watts)
        case "powerZone":
            guard let zone = alert.zone else { return nil }
            return PowerZoneAlert.power(zone: zone)
        default:
            return nil
        }
    }

    private func mapPurpose(_ purpose: String) -> IntervalStep.Purpose {
        switch purpose {
        case "work": return .work
        case "recovery": return .recovery
        default: return .work
        }
    }

    private func mapActivityType(_ type: String) -> HKWorkoutActivityType {
        switch type {
        case "running": return .running
        case "cycling": return .cycling
        case "walking": return .walking
        case "hiking": return .hiking
        case "swimming": return .swimming
        default: return .running
        }
    }

    private func mapLocation(_ location: String) -> HKWorkoutSessionLocationType {
        switch location {
        case "outdoor": return .outdoor
        case "indoor": return .indoor
        default: return .unknown
        }
    }

    private func mapLengthUnit(_ unit: String?) -> UnitLength {
        switch unit {
        case "meters": return .meters
        case "kilometers": return .kilometers
        case "miles": return .miles
        default: return .meters
        }
    }

    private func mapDurationUnit(_ unit: String?) -> UnitDuration {
        switch unit {
        case "seconds": return .seconds
        case "minutes": return .minutes
        default: return .seconds
        }
    }

    private func mapEnergyUnit(_ unit: String?) -> UnitEnergy {
        switch unit {
        case "kilocalories": return .kilocalories
        default: return .kilocalories
        }
    }

    private func mapSpeedUnit(_ unit: String?) -> UnitSpeed {
        switch unit {
        case "metersPerSecond": return .metersPerSecond
        case "kilometersPerHour": return .kilometersPerHour
        default: return .metersPerSecond
        }
    }
}
