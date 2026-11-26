//
//  ScheduledWorkoutsView.swift
//  OpenHealthSync
//
//  Displays scheduled workout plans and provides a button
//  to fetch new workouts from the training API queue.
//

import SwiftUI
import SwiftData
import WorkoutKit
import HealthKit

struct TrainingTabView: View {
    var scheduleManager: WorkoutScheduleManager
    var workoutManager: WorkoutManager
    var missedWorkoutDetector: MissedWorkoutDetector
    @Environment(\.modelContext) private var modelContext
    @Environment(SetbackStore.self) private var setbackStore
    @Query private var feedbackEntries: [WorkoutFeedback]
    @State private var viewMode: ViewMode = .timeline
    @State private var selectedDate: Date?
    @State private var feedbackWorkout: MissedWorkoutInfo?
    @State private var doingToday: MissedWorkoutInfo?
    /// How many past workouts the Training tab lists before linking to
    /// the full history screen.
    private let pastWorkoutsLimit = 10
    @AppStorage("onboardingSeededGoal") private var onboardingSeededGoal = false
    @AppStorage("onboardingNudgeDismissed") private var onboardingNudgeDismissed = false

    enum ViewMode: String, CaseIterable {
        case timeline, list
    }

    /// Show the "tell your coach" nudge once onboarding seeded a goal but no
    /// plan is lined up yet, until the athlete dismisses it.
    private var showOnboardingNudge: Bool {
        onboardingSeededGoal && !onboardingNudgeDismissed && scheduleManager.activePlan == nil
    }

    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    /// Whether the list's hero section leads with the run plan card (or its
    /// loading placeholder) — the strength card only needs a gap above it then.
    private var hasRunPlanCard: Bool {
        scheduleManager.activePlan != nil || scheduleManager.isLoadingPlan
    }

    private var upcomingWorkouts: [ScheduledWorkoutPlan] {
        scheduleManager.scheduledWorkouts
            .filter { workout in
                guard !workout.complete else { return false }
                let scheduledDate = Calendar.current.date(from: workout.date) ?? .distantFuture
                return scheduledDate >= startOfToday
            }
            .sorted {
                let date0 = Calendar.current.date(from: $0.date) ?? .distantFuture
                let date1 = Calendar.current.date(from: $1.date) ?? .distantFuture
                return date0 < date1
            }
    }

    private var missedWorkoutsInList: [ScheduledWorkoutPlan] {
        scheduleManager.scheduledWorkouts
            .filter { workout in
                guard !workout.complete else { return false }
                let scheduledDate = Calendar.current.date(from: workout.date) ?? .distantFuture
                return scheduledDate < startOfToday
            }
            .sorted {
                let date0 = Calendar.current.date(from: $0.date) ?? .distantPast
                let date1 = Calendar.current.date(from: $1.date) ?? .distantPast
                return date0 > date1
            }
    }

    /// Misses that still belong to the active plan get an inline section;
    /// everything older lives in the Trends tab's Missed Days segment.
    private var missedCurrentPlanWorkouts: [ScheduledWorkoutPlan] {
        let currentPlanIds = Set(scheduleManager.planWorkouts.map(\.id))
        return missedWorkoutsInList.filter { currentPlanIds.contains($0.plan.id) }
    }

    private var completedWorkouts: [ScheduledWorkoutPlan] {
        scheduleManager.scheduledWorkouts
            .filter { $0.complete }
            .sorted {
                let date0 = Calendar.current.date(from: $0.date) ?? .distantPast
                let date1 = Calendar.current.date(from: $1.date) ?? .distantPast
                return date0 > date1
            }
    }

    private var pastWorkouts: [WorkoutSummary] {
        workoutManager.allWorkouts.sorted { $0.startDate > $1.startDate }
    }

    /// Display-only strength sessions from the unified calendar: everything
    /// upcoming plus completed ones (which keep their ✓), so a finished
    /// session doesn't vanish from the list.
    private var strengthSessions: [CalendarEntry] {
        scheduleManager.calendarEntries
            .filter { $0.kind == .strength && ($0.completed || ($0.day ?? .distantPast) >= startOfToday) }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        // ZStack (not Group): modifiers on a Group attach to the active switch
        // branch, so toggling modes rebuilt the toolbar and its glass
        // containers flashed square. A ZStack keeps the toolbar's host stable.
        ZStack {
            switch viewMode {
            case .timeline:
                TrainingCalendarView(
                    scheduleManager: scheduleManager,
                    workoutManager: workoutManager,
                    missedWorkoutDetector: missedWorkoutDetector,
                    scheduledWorkouts: scheduleManager.scheduledWorkouts,
                    selectedDate: $selectedDate
                )
            case .list:
                List {
                    if !missedWorkoutDetector.missedWorkouts.isEmpty {
                        LBSection(bare: true, gap: LB.Space.md) {
                            MissedWorkoutBanner(detector: missedWorkoutDetector)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }

                    // Open illness or injury: daily status and "I've recovered".
                    if !setbackStore.active.isEmpty {
                        LBSection(bare: true, gap: LB.Space.md) {
                            VStack(spacing: LB.Space.sm) { SetbackBanner() }
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }

                    // First-run nudge — onboarding seeded a goal but no plan yet.
                    if showOnboardingNudge {
                        LBSection(bare: true, gap: LB.Space.md) {
                            OnboardingNudgeCard {
                                withAnimation { onboardingNudgeDismissed = true }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }

                    // Plan wrap-up banner — the server marked a plan finishable.
                    if let finishable = scheduleManager.finishablePlan {
                        LBSection(bare: true, gap: LB.Space.md) {
                            PlanCompletionBanner(plan: finishable, scheduleManager: scheduleManager)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }

                    // Both hero cards share one section, a sibling gap apart,
                    // as on the timeline.
                    if hasRunPlanCard || scheduleManager.activeStrengthPlan != nil {
                        LBSection(bare: true) {
                            if let plan = scheduleManager.activePlan {
                                PlanOverviewCard(
                                    plan: plan,
                                    planWorkouts: scheduleManager.planWorkouts,
                                    scheduledWorkouts: scheduleManager.scheduledWorkouts
                                )
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            } else if scheduleManager.isLoadingPlan {
                                PlanLoadingPlaceholder()
                                    .listRowInsets(EdgeInsets())
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }

                            if let strengthPlan = scheduleManager.activeStrengthPlan {
                                // Hidden-link overlay: a visible NavigationLink
                                // as row content would get the List's own
                                // chevron on top of the card's, diverging from
                                // the timeline.
                                ZStack {
                                    NavigationLink {
                                        PlanDetailView(plan: strengthPlan, scheduleManager: scheduleManager)
                                    } label: {
                                        EmptyView()
                                    }
                                    .opacity(0)
                                    StrengthCycleCardLabel(plan: strengthPlan)
                                }
                                .padding(.top, hasRunPlanCard ? LB.Space.md : 0)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                            }
                        }
                    }

                    if !upcomingWorkouts.isEmpty {
                        LBSection {
                            ForEach(upcomingWorkouts, id: \.self) { scheduled in
                                NavigationLink {
                                    ScheduledWorkoutDetailView(scheduled: scheduled)
                                } label: {
                                    ScheduledWorkoutRow(scheduled: scheduled)
                                }
                                .contextMenu {
                                    if info(for: scheduled).canDoToday {
                                        Button {
                                            doingToday = info(for: scheduled)
                                        } label: {
                                            Label("Do It Today", systemImage: "figure.run")
                                        }
                                    }
                                    Button {
                                        feedbackWorkout = info(for: scheduled)
                                    } label: {
                                        Label("Change Plans…", systemImage: "calendar.badge.clock")
                                    }
                                }
                            }
                        } header: {
                            LBSectionHeader(title: "Upcoming Workouts")
                        }
                    }

                    // Only misses from the active plan stay inline; older ones
                    // are reachable through the Missed Days stats screen below.
                    if !missedCurrentPlanWorkouts.isEmpty {
                        LBSection {
                            ForEach(missedCurrentPlanWorkouts, id: \.self) { scheduled in
                                if let feedback = existingFeedback(for: scheduled) {
                                    // Already checked in — show reason and action
                                    HStack {
                                        ScheduledWorkoutRow(scheduled: scheduled, isMissed: true)
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: LB.Space.xxs) {
                                            Text("\(feedback.reason.emoji) \(feedback.reason.label)")
                                                .font(.lbBody(.secondary))
                                                .foregroundStyle(.secondary)
                                            Text(feedback.action.label)
                                                .font(.lbBody(.secondary, .medium))
                                                .foregroundStyle(LB.amber)
                                        }
                                    }
                                } else if let missedInfo = missedWorkoutDetector.missedInfo(for: scheduled.plan.id) {
                                    Button {
                                        feedbackWorkout = missedInfo
                                    } label: {
                                        ScheduledWorkoutRow(scheduled: scheduled, isMissed: true)
                                    }
                                } else {
                                    Button {
                                        feedbackWorkout = info(for: scheduled)
                                    } label: {
                                        ScheduledWorkoutRow(scheduled: scheduled, isMissed: true)
                                    }
                                }
                            }
                        } header: {
                            LBSectionHeader(title: "Missed")
                        }
                    }

                    // Display-only Hevy sessions — never enqueued to the watch.
                    if !strengthSessions.isEmpty {
                        LBSection {
                            ForEach(strengthSessions) { entry in
                                StrengthSessionRow(entry: entry, showsDate: true)
                            }
                        } header: {
                            LBSectionHeader(title: "Strength Sessions")
                        }
                    }

                    if !completedWorkouts.isEmpty {
                        LBSection {
                            ForEach(completedWorkouts, id: \.self) { scheduled in
                                NavigationLink {
                                    ScheduledWorkoutDetailView(scheduled: scheduled)
                                } label: {
                                    ScheduledWorkoutRow(scheduled: scheduled)
                                }
                            }
                        } header: {
                            LBSectionHeader(title: "Completed Workouts")
                        }
                    }

                    if !pastWorkouts.isEmpty {
                        LBSection {
                            ForEach(pastWorkouts.prefix(pastWorkoutsLimit)) { summary in
                                NavigationLink {
                                    WorkoutDetailView(
                                        summary: summary,
                                        workoutManager: workoutManager
                                    )
                                } label: {
                                    WorkoutRow(
                                        summary: summary,
                                        status: workoutManager.extractionStatuses[summary.id]
                                    )
                                }
                            }
                            if pastWorkouts.count > pastWorkoutsLimit {
                                // The rest live on their own screen, by
                                // month and with filters: paging through
                                // years of history here never got anywhere.
                                NavigationLink {
                                    WorkoutHistoryView(workoutManager: workoutManager)
                                } label: {
                                    Text("All workouts (\(pastWorkouts.count))")
                                        .font(.lbBody(.secondary, .medium))
                                        .foregroundStyle(LB.accent)
                                }
                            }
                        } header: {
                            LBSectionHeader(title: "Past Workouts")
                        }
                    }
                }
                .lbList()
            }
        }
        .navigationTitle("Training")
        .refreshable {
            await scheduleManager.refreshFromServer(modelContext: modelContext)
            await setbackStore.load()
        }
        .toolbar {
            // Silent while healthy; a warning dot when the server is
            // unreachable or the session died. Details live in Settings.
            ToolbarItem(placement: .navigationBarLeading) {
                ServerStatusToolbarDot()
            }
            ToolbarItem(placement: .principal) {
                Picker("View Mode", selection: $viewMode) {
                    Image(systemName: "calendar").tag(ViewMode.timeline)
                    Image(systemName: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
        }
        .sheet(item: $feedbackWorkout) { workout in
            MissedWorkoutFeedbackFlow(
                missedWorkouts: [workout],
                detector: missedWorkoutDetector
            )
        }
        .doItToday($doingToday)
        // Celebration sheet, covering both timeline and list modes. Presented
        // by a banner tap or the manager's post-sync auto-check; dismissing
        // without completing snoozes only the auto-present (the sheet handles
        // that in its onDisappear), the banner stays.
        .sheet(item: Binding(
            get: { scheduleManager.celebrationPlan },
            set: { scheduleManager.celebrationPlan = $0 }
        )) { plan in
            PlanCelebrationSheet(plan: plan, scheduleManager: scheduleManager)
        }
        .task {
            await scheduleManager.loadScheduledWorkouts()
            workoutManager.fetchAllRecentWorkouts()
            // A session counted by hand is only complete once its link is
            // known; checking before that reports it as missed.
            await scheduleManager.ensureSessionLinks()
            missedWorkoutDetector.checkForMissedWorkouts(
                scheduledWorkouts: scheduleManager.scheduledWorkouts,
                modelContext: modelContext
            )
        }
        .overlay {
            if viewMode == .list
                && scheduleManager.scheduledWorkouts.isEmpty
                && workoutManager.allWorkouts.isEmpty
                && scheduleManager.refreshState == .idle {
                ContentUnavailableView(
                    "No Workouts",
                    systemImage: "figure.run.circle",
                    description: Text("Tap \"Check for New Workouts\" to fetch plans, or complete a workout to see it here.")
                )
            }
        }
    }

    private func existingFeedback(for scheduled: ScheduledWorkoutPlan) -> WorkoutFeedback? {
        guard let scheduledDate = Calendar.current.date(from: scheduled.date) else { return nil }
        return feedbackEntries.first { $0.covers(workoutId: scheduled.plan.id, scheduledOn: scheduledDate) && !$0.dismissed }
    }

    private func info(for scheduled: ScheduledWorkoutPlan) -> MissedWorkoutInfo {
        MissedWorkoutInfo(
            id: scheduled.plan.id,
            displayName: workoutDisplayName(for: scheduled),
            scheduledDate: Calendar.current.date(from: scheduled.date) ?? Date()
        )
    }

    private func workoutDisplayName(for scheduled: ScheduledWorkoutPlan) -> String {
        switch scheduled.plan.workout {
        case .custom(let custom):
            return custom.displayName ?? "Custom Workout"
        case .goal(let goal):
            return "Goal: \(goal.activity.name)"
        case .pacer(let pacer):
            return "Pacer: \(pacer.activity.name)"
        case .swimBikeRun:
            return "Swim-Bike-Run"
        @unknown default:
            return "Workout"
        }
    }
}

// MARK: - Row

struct ScheduledWorkoutRow: View {
    let scheduled: ScheduledWorkoutPlan
    var isMissed: Bool = false

    var body: some View {
        HStack(spacing: LB.Space.md) {
            Image(systemName: isMissed ? "exclamationmark.triangle.fill" : "applewatch")
                .font(.system(size: 20))
                .foregroundStyle(isMissed ? LB.amber : LB.blue)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous).fill(LB.surfaceTile)
                )

            VStack(alignment: .leading, spacing: LB.Space.xs) {
                Text(workoutName)
                    .font(.lbDisplay(.subheadline, .semibold))
                    .foregroundStyle(LB.textPrimary)
                if let dateString = formattedDate {
                    Text(dateString)
                        .font(.lbMono(.caption))
                        .foregroundStyle(LB.textTertiary)
                }
            }

            Spacer()

            if scheduled.complete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LB.green)
            }
        }
        .padding(.vertical, LB.Space.xxs)
    }

    private var workoutName: String {
        switch scheduled.plan.workout {
        case .custom(let custom):
            return custom.displayName ?? "Custom Workout"
        case .goal(let goal):
            return "Goal: \(goal.activity.name)"
        case .pacer(let pacer):
            return "Pacer: \(pacer.activity.name)"
        case .swimBikeRun:
            return "Swim-Bike-Run"
        @unknown default:
            return "Workout"
        }
    }

    private var formattedDate: String? {
        let dc = scheduled.date
        guard let year = dc.year, let month = dc.month, let day = dc.day else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = dc.hour
        components.minute = dc.minute

        guard let date = Calendar.current.date(from: components) else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = dc.hour != nil ? .short : .none
        return formatter.string(from: date)
    }
}

// MARK: - Onboarding nudge

/// Shown on the training home after onboarding seeds a goal but before a plan
/// exists. Dismissible; never returns once dismissed.
private struct OnboardingNudgeCard: View {
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: LB.Space.md) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 18))
                .foregroundStyle(LB.accent)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous).fill(LB.accentTint())
                )

            VStack(alignment: .leading, spacing: LB.Space.xs) {
                Text("Ready when you are")
                    .font(.lbDisplay(.subheadline, .semibold))
                    .foregroundStyle(LB.textPrimary)
                Text("Tell your coach you're ready and they'll build your plan.")
                    .font(.lbBody(.secondary))
                    .foregroundStyle(LB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 6)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LB.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(LB.surfaceControl))
            }
            .buttonStyle(.plain)
        }
        .padding(LB.Space.lg)
        .lbCard(border: LB.accent.opacity(0.3))
    }
}

// MARK: - HKWorkoutActivityType name helper

private extension HKWorkoutActivityType {
    var name: String {
        switch self {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        default: return "Workout"
        }
    }
}
