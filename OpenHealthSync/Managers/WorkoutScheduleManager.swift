//
//  WorkoutScheduleManager.swift
//  OpenHealthSync
//
//  Fetches queued workout compositions from the training API and schedules
//  them on Apple Watch via WorkoutScheduler (composition→CustomWorkout
//  translation lives in WorkoutCompositionBuilder).
//

import Foundation
import HealthKit
import SwiftUI
import SwiftData
import UIKit
import WorkoutKit
import os

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
@Observable
class WorkoutScheduleManager {
    /// The watch's schedule, with two corrections. A session a workout is
    /// linked to reads as complete: WorkoutKit only completes a session that
    /// was started from the watch's own schedule. And a session taken off the
    /// watch because it was done some other way is still listed.
    private(set) var scheduledWorkouts: [ScheduledWorkoutPlan] = []
    /// The schedule exactly as WorkoutKit reports it.
    private var deviceScheduledWorkouts: [ScheduledWorkoutPlan] = []
    /// Sessions taken off the watch because a workout counts for them.
    private var retired = RetiredSessionStore()
    /// When the watch's sessions were seen open and done, to tell which
    /// workout a session was ticked off with.
    private var completionLog = WatchCompletionLog()
    /// Whether the server gave the links this launch. Cached ones are good
    /// enough to draw with, but not to take a session off the watch.
    private var didFetchSessionLinks = false
    /// Planned session → the workout that counts for it, from the server.
    private(set) var sessionLinks: [UUID: UUID] = [:]
    /// Whether the links were asked for this launch, successfully or not.
    private(set) var didLoadSessionLinks = false
    var refreshState: RefreshState = .idle
    var authorizationState: WorkoutScheduler.AuthorizationState = .notDetermined
    var activePlan: TrainingPlan?
    /// The active strength cycle, if any — display-only (Hevy routine markers),
    /// never scheduled to the watch. Can coexist with an active running plan.
    var activeStrengthPlan: TrainingPlan?
    var planWorkouts: [PlanWorkout] = []
    var isLoadingPlan = true
    var allPlans: [TrainingPlan] = []
    var isLoadingPlans = false
    /// Merged run + strength agenda from /api/schedule/calendar.
    var calendarEntries: [CalendarEntry] = []
    /// The plan the celebration sheet is showing (nil = no sheet). Set by a
    /// banner tap or by the post-sync auto-check.
    var celebrationPlan: TrainingPlan?
    /// Every active plan from the last fetch. `activePlan`/`activeStrengthPlan`
    /// keep one per activity type for the hero cards, but finishable detection
    /// must scan all of them: the coach creates follow-up blocks as `active`
    /// before they start, so a wrapped plan and its successor coexist.
    private(set) var activePlans: [TrainingPlan] = []

    /// Plans whose auto-presented celebration was dismissed this session.
    /// The banner keeps showing (the server's `finishable` flag persists until
    /// someone completes the plan) — this only stops the sheet re-popping
    /// uninvited.
    private var celebrationSnoozedIds: Set<UUID> = []

    private let apiClient: WorkoutAPIClient
    /// Uploads missed-workout feedback; owned here so views reach it through
    /// the manager they already hold.
    let feedbackSync: FeedbackSyncService
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
        self.feedbackSync = FeedbackSyncService(apiClient: apiClient)
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
        await reconcileWatchWithLinks()
        let current = await WorkoutScheduler.shared.scheduledWorkouts
        deviceScheduledWorkouts = current
        completionLog.note(current)
        applySessionLinks()

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

        didLoadScheduledWorkouts = true
        await syncCalendar()
    }

    /// The sessions still to do from today on, soonest first.
    var upcomingWorkouts: [ScheduledWorkoutPlan] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        func date(_ scheduled: ScheduledWorkoutPlan) -> Date {
            calendar.date(from: scheduled.date) ?? .distantFuture
        }
        return scheduledWorkouts
            .filter { !$0.complete && date($0) >= startOfToday }
            .sorted { date($0) < date($1) }
    }

    // MARK: - iOS Calendar

    /// Whether each half of the schedule has been read this launch. Until it
    /// has, an empty list means "not known yet", and syncing it would delete
    /// that half's events from the iOS Calendar only to add them back.
    private var didLoadScheduledWorkouts = false
    private var didLoadAgenda = false

    /// Mirrors the schedule into the iOS Calendar when the user has switched
    /// that on (Settings → Training). Cheap when nothing changed. Sessions
    /// already done are included, from the watch and from the active plan, so
    /// one that left the watch or predates the switch still gets its entry.
    /// Strength
    /// sessions come from the server; while it hasn't answered and nothing is
    /// cached, the ones already in Calendar are left as they are.
    func syncCalendar() async {
        guard CalendarSync.isEnabled, didLoadScheduledWorkouts else { return }
        await CalendarSync.shared.sync(
            items: CalendarSyncItem.items(
                scheduled: scheduledWorkouts,
                entries: calendarEntries,
                planWorkouts: planWorkouts
            ),
            strengthKnown: didLoadAgenda
        )
    }

    // MARK: - Cache-First Rendering

    private var didRestoreFromCache = false

    /// Renders the last successful server responses instantly (and offline)
    /// while the network refresh runs. One-shot per launch; live fetches
    /// overwrite whatever this restores. The cache is cleared on sign-out, so
    /// a restored payload always belongs to the signed-in account.
    private func restoreFromCache() async {
        guard !didRestoreFromCache else { return }
        didRestoreFromCache = true

        if let plans = await apiClient.cachedActivePlans() {
            applyActivePlans(plans)
            if let plan = activePlan,
               let workouts = await apiClient.cachedPlanWorkouts(planId: plan.id) {
                planWorkouts = workouts
            }
            // A cache hit is a known state (even "no plans") — no spinner.
            isLoadingPlan = false
        }
        if let response = await apiClient.cachedScheduleCalendar() {
            calendarEntries = response.entries
            didLoadAgenda = true
        }
        if let links = await apiClient.cachedWorkoutPlanLinks() {
            setSessionLinks(from: links)
        }
        if let plans = await apiClient.cachedAllPlans() {
            allPlans = plans
        }
    }

    private func applyActivePlans(_ plans: [TrainingPlan]) {
        activePlans = plans
        activePlan = plans.first { !$0.isStrength }
        activeStrengthPlan = plans.first { $0.isStrength }
    }

    // MARK: - Active Plan

    func loadActivePlan() async {
        await restoreFromCache()
        // Show the loading state only when there's nothing to render yet —
        // with cached content on screen the refresh happens silently.
        if activePlans.isEmpty {
            isLoadingPlan = true
        }
        defer { isLoadingPlan = false }
        do {
            // A running plan and a strength cycle can both be active.
            let plans = try await apiClient.fetchActivePlans()
            applyActivePlans(plans)

            if let plan = activePlan {
                planWorkouts = try await apiClient.fetchPlanWorkouts(planId: plan.id)
            } else {
                planWorkouts = []
            }
        } catch {
            AppLog.sync.error("Failed to load active plan: \(String(describing: error), privacy: .public)")
        }

        await loadSessionLinks()
        await loadScheduleCalendar()
    }

    // MARK: - Linking Workouts to Sessions

    /// The workout that counts for a planned session, if any.
    func linkedWorkoutId(forSession id: UUID) -> UUID? {
        sessionLinks[id]
    }

    /// Makes the links known before anything judges a session missed: the
    /// last ones the server gave (also offline), then this launch's. Without
    /// them a session counted by hand looks incomplete.
    func ensureSessionLinks() async {
        await restoreFromCache()
        if !didLoadSessionLinks {
            await loadSessionLinks()
        }
    }

    func loadSessionLinks() async {
        do {
            let changed = setSessionLinks(from: try await apiClient.fetchWorkoutPlanLinks())
            let firstFetch = !didFetchSessionLinks
            didFetchSessionLinks = true
            if changed || firstFetch {
                // A run recorded outside the plan may now count for a session
                // the watch still offers, or have stopped counting for one.
                await loadScheduledWorkouts()
            }
        } catch {
            AppLog.sync.error("Failed to load workout plan links: \(String(describing: error), privacy: .public)")
        }
        didLoadSessionLinks = true
    }

    /// Returns whether anything changed.
    @discardableResult
    private func setSessionLinks(from links: [WorkoutPlanLink]) -> Bool {
        var map: [UUID: UUID] = [:]
        // Newest first; the server keeps one workout per session, so a
        // duplicate can only be a stale row and the newest wins.
        for link in links {
            if let session = link.planWorkoutId, map[session] == nil {
                map[session] = link.id
            }
        }
        guard map != sessionLinks else { return false }
        sessionLinks = map
        applySessionLinks()
        return true
    }

    private func applySessionLinks() {
        let onDevice = Set(deviceScheduledWorkouts.map(\.plan.id))
        let device = deviceScheduledWorkouts.map { scheduled in
            guard !scheduled.complete, sessionLinks[scheduled.plan.id] != nil else { return scheduled }
            var done = scheduled
            done.complete = true
            return done
        }
        // One that is no longer linked reads as any session that wasn't done.
        let offWatch = retired.sessions.values
            .filter { !onDevice.contains($0.plan.id) }
            .map { session in
                var session = session
                session.complete = sessionLinks[session.plan.id] != nil
                return session
            }
        scheduledWorkouts = device + offWatch
    }

    /// Brings the watch in line with the links. A session a workout counts
    /// for leaves the watch when it is planned for today or later, because
    /// the watch would keep offering it; it is kept in `retired` so it stays
    /// in the calendar. Earlier ones are left alone: the watch no longer
    /// offers them. A retired session that stopped counting and is still due
    /// goes back on the watch.
    private func reconcileWatchWithLinks() async {
        guard didFetchSessionLinks,
              await WorkoutScheduler.shared.authorizationState == .authorized else { return }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        func isDue(_ scheduled: ScheduledWorkoutPlan) -> Bool {
            (calendar.date(from: scheduled.date) ?? .distantPast) >= startOfToday
        }

        let onDevice = await WorkoutScheduler.shared.scheduledWorkouts
        for scheduled in onDevice {
            let id = scheduled.plan.id
            guard !scheduled.complete, sessionLinks[id] != nil, isDue(scheduled) else {
                // The watch has it (again), so its copy is the one to go by.
                retired.remove(id: id)
                continue
            }
            guard retired.add(scheduled) else { continue }
            await WorkoutScheduler.shared.remove(scheduled.plan, at: scheduledDateMap[id] ?? scheduled.date)
            AppLog.scheduling.info("Took session \(id, privacy: .public) off the watch: a workout counts for it")
        }

        let present = Set(onDevice.map(\.plan.id))
        for session in retired.sessions.values
        where sessionLinks[session.plan.id] == nil && isDue(session) && !present.contains(session.plan.id) {
            await WorkoutScheduler.shared.schedule(session.plan, at: session.date)
            scheduledDateMap[session.plan.id] = session.date
            retired.remove(id: session.plan.id)
            AppLog.scheduling.info("Put session \(session.plan.id, privacy: .public) back on the watch: no workout counts for it now")
        }
    }

    /// The session the server already counts this workout for, if any.
    func sessionCounted(for workoutId: UUID) -> UUID? {
        sessionLinks.first { $0.value == workoutId }?.key
    }

    /// The workouts that already count for a session.
    var countedWorkoutIds: Set<UUID> {
        Set(sessionLinks.values)
    }

    /// A session the watch has ticked off and no workout counts for yet.
    struct TickedSession {
        let id: UUID
        let activity: HKWorkoutActivityType
        let window: WatchCompletionLog.Window
        /// A workout was put forward for it before.
        let wasOffered: Bool
    }

    /// The sessions the watch has ticked off without a workout counting for
    /// them: started from the watch's schedule, which offers a session for
    /// days either side of its own, so on any day and at any hour. Only
    /// those seen to go from open to done, since that is what says when.
    func tickedSessionsAwaitingWorkout() async -> [TickedSession] {
        let onDevice = await WorkoutScheduler.shared.scheduledWorkouts
        completionLog.note(onDevice)
        return onDevice.compactMap { scheduled in
            let id = scheduled.plan.id
            guard scheduled.complete, sessionLinks[id] == nil,
                  let activity = scheduled.plan.activityType,
                  let window = completionLog.window(for: id)
            else { return nil }
            return TickedSession(id: id, activity: activity, window: window, wasOffered: completionLog.wasOffered(id))
        }
    }

    /// Remembers that a workout was put forward for a ticked session.
    func noteWorkoutOffered(forSession id: UUID) {
        completionLog.markOffered(id)
    }

    /// Counts a recorded workout for a planned session, or with a nil session
    /// stops counting it. The server decides; nothing changes here when it
    /// can't be reached. A session that is still due leaves the watch, since
    /// it has now been done, and keeps its place in the calendar.
    @discardableResult
    func setPlanLink(workoutId: UUID, sessionId: UUID?) async throws -> WorkoutContext {
        let context = try await apiClient.setWorkoutPlanLink(workoutId: workoutId, planWorkoutId: sessionId)

        var links = sessionLinks.filter { $0.value != workoutId }
        if let sessionId {
            links[sessionId] = workoutId
        }
        sessionLinks = links
        // Applies the links, and moves sessions on or off the watch for them.
        await loadScheduledWorkouts()

        Task { await refreshAfterPlanChange() }
        return context
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
            didLoadAgenda = true
        } catch {
            // Best-effort: keep whatever agenda we already have.
            AppLog.sync.error("Failed to load schedule calendar: \(String(describing: error), privacy: .public)")
        }
        await syncCalendar()
    }

    /// Fetches a plan's expanded cadence (dated sessions + conflict warnings)
    /// on demand for the plan detail screen.
    func schedule(forPlan planId: UUID) async -> PlanScheduleResponse? {
        do {
            return try await apiClient.fetchPlanSchedule(planId: planId)
        } catch {
            AppLog.sync.error("Failed to load schedule for plan \(planId, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Loads every plan so the plans browser can group them into
    /// upcoming / current / archived.
    func loadAllPlans() async {
        await restoreFromCache()
        isLoadingPlans = allPlans.isEmpty
        defer { isLoadingPlans = false }
        do {
            allPlans = try await apiClient.fetchAllPlans()
        } catch {
            AppLog.sync.error("Failed to load plans: \(String(describing: error), privacy: .public)")
        }
    }

    /// Fetches the workouts for a specific plan on demand (used by the plan
    /// detail view for plans other than the active one).
    func workouts(forPlan planId: UUID) async -> [PlanWorkout] {
        do {
            return try await apiClient.fetchPlanWorkouts(planId: planId)
        } catch {
            AppLog.sync.error("Failed to load workouts for plan \(planId, privacy: .public): \(String(describing: error), privacy: .public)")
            return []
        }
    }

    // MARK: - Sync Workout Inventory to Server

    /// Reports all locally-scheduled workout IDs to the server so the LLM can
    /// target them for edit/delete actions, even if they predate the queue system.
    func syncWorkoutInventory() async {
        let workouts = await WorkoutScheduler.shared.scheduledWorkouts
        let inventory = workouts.map { scheduled in
            return WorkoutInventoryItem(
                id: scheduled.plan.id,
                displayName: scheduled.plan.displayTitle,
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
            AppLog.sync.error("Failed to sync workout inventory: \(String(describing: error), privacy: .public)")
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
                AppLog.sync.info("Auto-sync found \(queue.count) queued workouts, \(actions.count) pending actions")
                await refreshFromServer(modelContext: modelContext)
                await loadActivePlan()
            } else {
                // Nothing new, but this device may still lack runs it never
                // received (reinstall, new phone). Before the inventory, so
                // the server hears about what was restored.
                await restoreMissingWorkouts()
                // Still sync inventory to report completion status
                await syncWorkoutInventory()
                // Keep the merged agenda fresh (strength sessions can be
                // added or completed without any queue work existing).
                await loadScheduleCalendar()
            }
        } catch {
            // Silent failure — auto-sync is best-effort
            AppLog.sync.error("Auto-sync check failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Refresh from Server

    func refreshFromServer(modelContext: ModelContext? = nil) async {
        // Sync any unsynced feedback entries first
        if let modelContext {
            await feedbackSync.syncUnsyncedFeedback(modelContext: modelContext)
        }

        refreshState = .syncing(step: .inventory)
        await syncWorkoutInventory()

        refreshState = .syncing(step: .actions)
        await syncEditsAndDeletes()

        refreshState = .syncing(step: .fetching)
        do {
            let queue = try await apiClient.fetchQueue()

            var scheduled = 0
            for (index, composition) in queue.enumerated() {
                refreshState = .scheduling(current: index + 1, total: queue.count)

                do {
                    try await scheduleOnWatch(composition)
                    try await apiClient.updateQueueItemStatus(id: composition.id, status: "synced")
                    scheduled += 1
                } catch {
                    AppLog.scheduling.error("Failed to schedule '\(composition.displayName, privacy: .public)': \(String(describing: error), privacy: .public)")
                }
            }

            // After the pending items, so a new run is never crowded out of
            // the WorkoutKit limit by an older one being restored.
            let restored = await restoreMissingWorkouts()
            if restored > 0 {
                // The inventory went up at the start of this refresh, before
                // the restored runs existed.
                await syncWorkoutInventory()
            }

            await loadScheduledWorkouts()
            refreshState = .done(count: scheduled + restored)

        } catch {
            refreshState = .failed(message: error.localizedDescription)
        }
    }

    /// Builds a composition's CustomWorkout and schedules it under the queue
    /// item's id, recording the date `remove(_:at:)` will need later.
    private func scheduleOnWatch(_ composition: QueuedWorkoutComposition) async throws {
        let customWorkout = try WorkoutCompositionBuilder.buildCustomWorkout(
            from: composition,
            alertEvery: DistanceAlert.currentInterval()
        )
        let plan = WorkoutPlan(.custom(customWorkout), id: composition.id)

        let dateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: composition.scheduledDate
        )

        await WorkoutScheduler.shared.schedule(plan, at: dateComponents)
        scheduledDateMap[composition.id] = dateComponents
    }

    // MARK: - Distance Alerts

    /// Rebuilds the runs already on the watch after the distance alert
    /// setting changed; new ones pick it up as they are scheduled. Each run
    /// keeps the day the watch has it on. Best-effort: a run the server can't
    /// describe right now keeps its old alerts.
    func reapplyDistanceAlerts() async {
        guard await WorkoutScheduler.shared.authorizationState == .authorized else { return }

        let expected: [QueuedWorkoutComposition]
        do {
            expected = try await apiClient.fetchScheduledQueue(from: Calendar.current.startOfDay(for: Date()))
        } catch {
            AppLog.sync.error("Failed to fetch scheduled workouts to reapply distance alerts: \(String(describing: error), privacy: .public)")
            return
        }

        let alertEvery = DistanceAlert.currentInterval()
        let onDevice = await WorkoutScheduler.shared.scheduledWorkouts
        var rebuilt = 0
        for composition in expected {
            guard let current = onDevice.first(where: { $0.plan.id == composition.id }), !current.complete,
                  let workout = try? WorkoutCompositionBuilder.buildCustomWorkout(from: composition, alertEvery: alertEvery)
            else { continue }
            if case .custom(let existing) = current.plan.workout, existing == workout { continue }

            let date = scheduledDateMap[composition.id] ?? current.date
            await WorkoutScheduler.shared.remove(current.plan, at: date)
            await WorkoutScheduler.shared.schedule(WorkoutPlan(.custom(workout), id: composition.id), at: date)
            scheduledDateMap[composition.id] = date
            rebuilt += 1
        }
        guard rebuilt > 0 else { return }
        AppLog.scheduling.info("Rebuilt \(rebuilt) runs for the distance alert setting")
        await loadScheduledWorkouts()
    }

    // MARK: - Restore Missing Workouts

    /// Re-schedules delivered runs this device's watch doesn't have. The
    /// server marks a queue item `synced` once for the whole account, so after
    /// a reinstall or on a new phone the pending queue is empty while the plan
    /// still has upcoming runs, and without this the watch, calendar and
    /// "Upcoming" list stay empty. Nothing is confirmed back, since the items
    /// are already `synced`. Returns how many runs were scheduled.
    @discardableResult
    func restoreMissingWorkouts() async -> Int {
        // Without WorkoutKit authorization nothing can be scheduled, and an
        // unreadable schedule would make every run look missing.
        guard await WorkoutScheduler.shared.authorizationState == .authorized else { return 0 }

        let expected: [QueuedWorkoutComposition]
        do {
            expected = try await apiClient.fetchScheduledQueue(from: Calendar.current.startOfDay(for: Date()))
        } catch {
            // Best-effort. A server before 0.1.14 404s here; Settings already
            // flags it as behind, and pending-queue sync is unaffected.
            AppLog.sync.error("Failed to fetch scheduled workouts for restore: \(String(describing: error), privacy: .public)")
            return 0
        }

        let onDevice = await WorkoutScheduler.shared.scheduledWorkouts
        let missing = Self.workoutsToRestore(
            expected: expected,
            // A retired session isn't missing. The server stops expecting
            // one once it is completed, which can land a moment later.
            onDevice: Set(onDevice.map(\.plan.id)).union(retired.sessions.keys),
            // Completed workouts linger in the schedule. Counting them could
            // leave no room at all, while an attempt past the real limit just
            // doesn't land and is retried next sync.
            room: WorkoutScheduler.maxAllowedScheduledWorkoutCount - onDevice.filter { !$0.complete }.count
        )
        guard !missing.isEmpty else { return 0 }

        var restored = 0
        for composition in missing {
            do {
                try await scheduleOnWatch(composition)
                restored += 1
            } catch {
                AppLog.scheduling.error("Failed to restore '\(composition.displayName, privacy: .public)': \(String(describing: error), privacy: .public)")
            }
        }
        AppLog.sync.info("Restored \(restored) of \(missing.count) workouts missing from this device")
        await loadScheduledWorkouts()
        return restored
    }

    /// The expected runs missing from the device, soonest first, capped at
    /// the room WorkoutKit has left. When a long plan exceeds the limit the
    /// nearest runs win, and later syncs add the rest as earlier ones finish.
    static func workoutsToRestore(
        expected: [QueuedWorkoutComposition],
        onDevice: Set<UUID>,
        room: Int
    ) -> [QueuedWorkoutComposition] {
        let missing = expected
            .filter { !onDevice.contains($0.id) }
            .sorted { $0.scheduledDate < $1.scheduledDate }
        return Array(missing.prefix(max(room, 0)))
    }

    // MARK: - Remove All

    func removeAll() async {
        await WorkoutScheduler.shared.removeAllWorkouts()
        scheduledDateMap = [:]
        retired.removeAll()
        completionLog.removeAll()
        await loadScheduledWorkouts()
    }

    // MARK: - Remove Single Workout

    func removeWorkout(id: UUID) async -> Bool {
        if await isAbsentFromDevice(id), retired.remove(id: id) {
            scheduledDateMap.removeValue(forKey: id)
            await loadScheduledWorkouts()
            return true
        }

        guard let dateComponents = scheduledDateMap[id] else {
            AppLog.scheduling.warning("No stored date for workout \(id, privacy: .public), cannot remove")
            return false
        }

        // Find the matching plan in the scheduler
        let allScheduled = await WorkoutScheduler.shared.scheduledWorkouts
        guard let match = allScheduled.first(where: { $0.plan.id == id }) else {
            AppLog.scheduling.warning("Workout \(id, privacy: .public) not found in scheduler")
            scheduledDateMap.removeValue(forKey: id)
            return false
        }

        await WorkoutScheduler.shared.remove(match.plan, at: dateComponents)
        scheduledDateMap.removeValue(forKey: id)
        await loadScheduledWorkouts()
        return true
    }

    /// True only when WorkoutKit is readable and doesn't hold the workout.
    /// Unauthorized, an empty read proves nothing.
    private func isAbsentFromDevice(_ id: UUID) async -> Bool {
        guard await WorkoutScheduler.shared.authorizationState == .authorized else { return false }
        return !(await WorkoutScheduler.shared.scheduledWorkouts).contains { $0.plan.id == id }
    }

    // MARK: - Reschedule Workout (same workout, new date)

    /// Moves a workout to a new date without changing its content.
    /// Used by the missed workout feedback flow when the user taps "Reschedule".
    func rescheduleWorkout(id: UUID, to newDate: Date) async -> Bool {
        // Find the existing plan in the scheduler, or among the sessions
        // taken off the watch: one that was unlinked after its day can
        // still be moved.
        let allScheduled = await WorkoutScheduler.shared.scheduledWorkouts
        guard let plan = allScheduled.first(where: { $0.plan.id == id })?.plan ?? retired.sessions[id]?.plan else {
            AppLog.scheduling.warning("Workout \(id, privacy: .public) not found in scheduler for reschedule")
            return false
        }

        // Remove from old date
        let removed = await removeWorkout(id: id)
        if !removed {
            AppLog.scheduling.warning("Could not remove workout \(id, privacy: .public) from old date for reschedule")
        }

        // Schedule at new date
        let newDateComponents = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: newDate
        )

        await WorkoutScheduler.shared.schedule(plan, at: newDateComponents)
        scheduledDateMap[id] = newDateComponents
        await loadScheduledWorkouts()
        return true
    }

    // MARK: - Change Plans Ahead of Time

    /// Skips a run that isn't due yet, for a reason, and files the check-in.
    /// Throws when the server can't be told, and then nothing has changed.
    /// The caller runs `refreshAfterPlanChange()` afterwards.
    func skipUpcoming(
        _ workout: MissedWorkoutInfo,
        reason: MissedWorkoutReason,
        note: String?,
        modelContext: ModelContext
    ) async throws {
        let feedback = WorkoutFeedback(
            workoutId: workout.id,
            workoutName: workout.displayName,
            scheduledDate: workout.scheduledDate,
            reason: reason,
            action: .skip,
            reasonNote: note
        )
        try await skipUpcomingWorkout(feedback.payload)
        feedback.synced = true
        modelContext.insert(feedback)
    }

    /// Moves a run that isn't due yet to `newDate`, for a reason, and files
    /// the check-in. `others` are the runs on that day to skip to make room;
    /// the ones the server couldn't be told about are returned, and stay on.
    /// Throws when the server can't be told about the move itself, and then
    /// nothing has changed. The caller runs `refreshAfterPlanChange()`
    /// afterwards.
    func moveUpcoming(
        _ workout: MissedWorkoutInfo,
        to newDate: Date,
        reason: MissedWorkoutReason,
        note: String?,
        skipping others: [MissedWorkoutInfo],
        modelContext: ModelContext
    ) async throws -> [MissedWorkoutInfo] {
        let feedback = WorkoutFeedback(
            workoutId: workout.id,
            workoutName: workout.displayName,
            scheduledDate: workout.scheduledDate,
            reason: reason,
            action: .move,
            reasonNote: note,
            newDate: newDate
        )
        try await moveUpcomingWorkout(feedback.payload, to: newDate)
        feedback.synced = true
        modelContext.insert(feedback)
        return await skipToMakeRoom(others, for: workout, modelContext: modelContext)
    }

    /// The server hears first: the restore pass re-adds any due run the
    /// server still expects, so removing it from the watch before the skip
    /// lands would only bring it back.
    private func skipUpcomingWorkout(_ feedback: WorkoutFeedbackPayload) async throws {
        try await apiClient.submitFeedback(feedback)
        if !(await removeWorkout(id: feedback.workoutId)) {
            AppLog.scheduling.warning("Skipped workout \(feedback.workoutId, privacy: .public) on the server but couldn't remove it from the watch")
        }
    }

    /// The server hears first, so a failure leaves the run where it was on
    /// both sides. If the watch then can't re-date it, the server already has
    /// the new day.
    private func moveUpcomingWorkout(_ feedback: WorkoutFeedbackPayload, to newDate: Date) async throws {
        try await apiClient.submitFeedback(feedback)
        if !(await rescheduleWorkout(id: feedback.workoutId, to: newDate)) {
            AppLog.scheduling.warning("Moved workout \(feedback.workoutId, privacy: .public) on the server but couldn't re-date it on the watch")
        }
    }

    /// Brings a run planned for a later day forward to today, in one step and
    /// without asking why: doing a run early is no setback to explain. The
    /// server takes a reason from a fixed list, and none of them is "I felt
    /// like it sooner", so the note says what happened. Otherwise as
    /// `moveUpcoming`.
    func bringForwardToToday(
        _ workout: MissedWorkoutInfo,
        skipping others: [MissedWorkoutInfo],
        modelContext: ModelContext
    ) async throws -> [MissedWorkoutInfo] {
        try await moveUpcoming(
            workout,
            to: workout.time(on: Date()),
            reason: .other,
            note: "Brought forward to do today",
            skipping: others,
            modelContext: modelContext
        )
    }

    /// The sessions on `day` that are still to do, other than the one with
    /// `id`: what a run moved onto that day would share it with.
    func openSessions(on day: Date, otherThan id: UUID) -> [MissedWorkoutInfo] {
        let calendar = Calendar.current
        return scheduledWorkouts.compactMap { scheduled in
            guard !scheduled.complete, scheduled.plan.id != id,
                  let date = calendar.date(from: scheduled.date),
                  calendar.isDate(date, inSameDayAs: day)
            else { return nil }
            return MissedWorkoutInfo(id: scheduled.plan.id, displayName: scheduled.plan.displayTitle, scheduledDate: date)
        }
    }

    /// Skips the runs on the day `moved` went to. Returns the ones the server
    /// couldn't be told about, which stay on the watch.
    func skipToMakeRoom(
        _ others: [MissedWorkoutInfo],
        for moved: MissedWorkoutInfo,
        modelContext: ModelContext
    ) async -> [MissedWorkoutInfo] {
        var stillOn: [MissedWorkoutInfo] = []
        for other in others {
            do {
                try await skipUpcoming(
                    other, reason: .other, note: "Made room for \(moved.displayName)", modelContext: modelContext
                )
            } catch {
                AppLog.scheduling.error("Failed to skip workout \(other.id, privacy: .public) to make room: \(String(describing: error), privacy: .public)")
                stillOn.append(other)
            }
        }
        return stillOn
    }

    /// The coach reads the device inventory, and the plan card counts the
    /// plan's runs, so both should reflect a change right away. Run once after
    /// a whole change (a move plus the skips it made room with), so two
    /// inventory uploads can't race each other.
    func refreshAfterPlanChange() async {
        await syncWorkoutInventory()
        await loadActivePlan()
    }

    // MARK: - Edit Workout (remove + re-schedule)

    func editWorkout(id: UUID, composition: QueuedWorkoutComposition) async -> Bool {
        // Remove the old version
        let removed = await removeWorkout(id: id)
        if !removed {
            AppLog.scheduling.warning("Could not remove old workout \(id, privacy: .public) for edit")
        }

        // Schedule the updated version
        do {
            try await scheduleOnWatch(composition)
            await loadScheduledWorkouts()
            return true
        } catch {
            AppLog.scheduling.error("Failed to schedule edited workout: \(String(describing: error), privacy: .public)")
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
                    var success = await removeWorkout(id: action.workoutId)
                    // Not on this device (a fresh install that never got
                    // it) is already what the delete asks for. Ack it, so the
                    // server retires the item as skipped; unacked, the action
                    // would sit forever and the restore pass would keep
                    // putting the run back.
                    if !success {
                        success = await isAbsentFromDevice(action.workoutId)
                    }
                    if success {
                        try? await apiClient.acknowledgePendingAction(id: action.id)
                    }

                case "edit":
                    guard let composition = action.composition else {
                        AppLog.sync.warning("Edit action \(action.id, privacy: .public) missing composition")
                        continue
                    }
                    let success = await editWorkout(id: action.workoutId, composition: composition)
                    if success {
                        try? await apiClient.acknowledgePendingAction(id: action.id)
                    }

                default:
                    AppLog.sync.warning("Unknown action type: \(action.action, privacy: .public)")
                }
            }
        } catch {
            AppLog.sync.error("Failed to sync edits/deletes: \(String(describing: error), privacy: .public)")
        }
    }

}
