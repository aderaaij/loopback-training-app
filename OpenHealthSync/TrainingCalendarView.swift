import SwiftUI
import SwiftData
import WorkoutKit
import HealthKit

struct TrainingCalendarView: View {
    @ObservedObject var scheduleManager: WorkoutScheduleManager
    @ObservedObject var workoutManager: WorkoutManager
    @ObservedObject var missedWorkoutDetector: MissedWorkoutDetector
    let scheduledWorkouts: [ScheduledWorkoutPlan]
    @Binding var selectedDate: Date?

    @State private var resolvedSelectedDate: Date = Date()

    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true

    private var calendar: Calendar {
        var cal = Calendar.current
        cal.firstWeekday = weekStartsOnMonday ? 2 : 1
        return cal
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // Missed workout banner
                if !missedWorkoutDetector.missedWorkouts.isEmpty {
                    MissedWorkoutBanner(detector: missedWorkoutDetector)
                        .padding(.bottom, 8)
                }

                // Plan wrap-up banner — the server marked a plan finishable.
                if let finishable = scheduleManager.finishablePlan {
                    PlanCompletionBanner(plan: finishable, scheduleManager: scheduleManager)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }

                // Plan overview
                Group {
                    if let plan = scheduleManager.activePlan {
                        PlanOverviewCard(
                            plan: plan,
                            planWorkouts: scheduleManager.planWorkouts,
                            scheduledWorkouts: scheduledWorkouts
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    } else if scheduleManager.isLoadingPlan {
                        PlanLoadingPlaceholder()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: scheduleManager.activePlan != nil)
                .padding(.horizontal)
                .padding(.bottom, 16)

                // Active strength cycle (display-only Hevy cadence)
                if let strengthPlan = scheduleManager.activeStrengthPlan {
                    StrengthCycleCard(plan: strengthPlan, scheduleManager: scheduleManager)
                        .padding(.horizontal)
                        .padding(.bottom, 16)
                }

                // Week strip
                WeekStripView(
                    timelineItems: timelineItemsByDay,
                    selectedDate: $resolvedSelectedDate
                )

                // Selected day's workouts
                DayDetailSection(
                    date: resolvedSelectedDate,
                    items: selectedDayItems,
                    workoutManager: workoutManager,
                    missedWorkoutDetector: missedWorkoutDetector
                )
                .padding(.top, 4)
            }
            .padding(.bottom)
        }
        .contentMargins(.top, 0)
        .background(LB.bg)
        .onAppear {
            resolvedSelectedDate = selectedDate ?? Date()
            workoutManager.fetchAllRecentWorkouts()
        }
        .onChange(of: resolvedSelectedDate) { _, newValue in
            selectedDate = newValue
        }
    }

    // MARK: - Merged Data

    private var timelineItemsByDay: [DateComponents: [TrainingTimelineItem]] {
        var dict: [DateComponents: [TrainingTimelineItem]] = [:]

        // Collect completed plan IDs so we can deduplicate past workouts
        let completedPlanIds = Set(
            scheduledWorkouts
                .filter { $0.complete }
                .map { $0.plan.id }
        )

        for plan in scheduledWorkouts {
            let item = TrainingTimelineItem.scheduledPlan(plan)
            dict[item.dayComponents, default: []].append(item)
        }

        // Strength sessions from the unified schedule calendar (display-only).
        // Runs from the feed are skipped: they already appear via the
        // WorkoutKit schedule above.
        var completedStrengthDays: Set<DateComponents> = []
        for entry in scheduleManager.calendarEntries where entry.kind == .strength {
            let item = TrainingTimelineItem.strengthSession(entry)
            dict[item.dayComponents, default: []].append(item)
            if entry.completed {
                completedStrengthDays.insert(item.dayComponents)
            }
        }

        for summary in workoutManager.allWorkouts {
            // Skip past workouts that match a completed scheduled plan —
            // the plan row already shows the completion status
            if matchesCompletedPlan(summary, completedPlanIds: completedPlanIds) {
                continue
            }
            // Likewise skip strength workouts on days whose scheduled session
            // is completed — the session row carries the ✓ and links to it.
            if summary.activityType == "traditionalStrength",
               completedStrengthDays.contains(
                   calendar.dateComponents([.year, .month, .day], from: summary.startDate)
               ) {
                continue
            }
            let item = TrainingTimelineItem.pastWorkout(summary)
            dict[item.dayComponents, default: []].append(item)
        }

        for key in dict.keys {
            dict[key]?.sort { $0.date < $1.date }
        }

        return dict
    }

    /// Check if a past workout corresponds to a completed scheduled plan.
    private func matchesCompletedPlan(_ summary: WorkoutSummary, completedPlanIds: Set<UUID>) -> Bool {
        guard !completedPlanIds.isEmpty else { return false }

        // Match by time proximity: if a past workout starts within ±1 hour
        // of a completed plan's scheduled date, it's the same workout
        let oneHour: TimeInterval = 3600
        for plan in scheduledWorkouts where plan.complete {
            guard let scheduledDate = calendar.date(from: plan.date) else { continue }
            let timeDiff = abs(summary.startDate.timeIntervalSince(scheduledDate))
            if timeDiff <= oneHour {
                return true
            }
        }
        return false
    }

    private var selectedDayItems: [TrainingTimelineItem] {
        let dc = calendar.dateComponents([.year, .month, .day], from: resolvedSelectedDate)
        return timelineItemsByDay[dc] ?? []
    }
}

// MARK: - Day Detail Section

private struct DayDetailSection: View {
    let date: Date
    let items: [TrainingTimelineItem]
    @ObservedObject var workoutManager: WorkoutManager
    @ObservedObject var missedWorkoutDetector: MissedWorkoutDetector

    @Environment(\.modelContext) private var modelContext
    @State private var feedbackWorkout: MissedWorkoutInfo?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(date, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.lbDisplay(17, .semibold))
                    .foregroundStyle(LB.textPrimary)
                    .padding(.horizontal)

                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(LB.textMuted)
                        Text("Rest & recover")
                            .font(.lbDisplay(16, .semibold))
                            .foregroundStyle(LB.textSecondary)
                        Text("No scheduled workout. An easy walk is optional — let HRV climb back.")
                            .font(.lbBody(13))
                            .foregroundStyle(LB.textMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 240)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    ForEach(items) { item in
                        timelineItemRow(item)
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .padding(.horizontal)
        }
        .sheet(item: $feedbackWorkout) { workout in
            MissedWorkoutFeedbackFlow(
                missedWorkouts: [workout],
                detector: missedWorkoutDetector
            )
        }
    }

    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private func isPastDue(_ plan: ScheduledWorkoutPlan) -> Bool {
        guard !plan.complete else { return false }
        let scheduledDate = Calendar.current.date(from: plan.date) ?? .distantFuture
        return scheduledDate < startOfToday
    }

    private func existingFeedback(for workoutId: UUID) -> WorkoutFeedback? {
        let descriptor = FetchDescriptor<WorkoutFeedback>()
        guard let allFeedback = try? modelContext.fetch(descriptor) else { return nil }
        return allFeedback.first { $0.workoutId == workoutId && !$0.dismissed }
    }

    /// Find the HealthKit strength workout that completed a scheduled
    /// strength session (same local day, matching the server's auto-match).
    private func matchedStrengthWorkout(for entry: CalendarEntry) -> WorkoutSummary? {
        guard let day = entry.day else { return nil }
        return workoutManager.allWorkouts
            .filter {
                $0.activityType == "traditionalStrength"
                    && Calendar.current.isDate($0.startDate, inSameDayAs: day)
            }
            .min(by: { $0.startDate < $1.startDate })
    }

    /// Find the matching HKWorkout summary for a completed plan workout.
    private func matchedWorkout(for plan: ScheduledWorkoutPlan) -> WorkoutSummary? {
        guard plan.complete else { return nil }
        guard let scheduledDate = Calendar.current.date(from: plan.date) else { return nil }
        let oneHour: TimeInterval = 3600

        return workoutManager.allWorkouts
            .filter { abs($0.startDate.timeIntervalSince(scheduledDate)) <= oneHour }
            .min(by: { abs($0.startDate.timeIntervalSince(scheduledDate)) < abs($1.startDate.timeIntervalSince(scheduledDate)) })
    }

    @ViewBuilder
    private func timelineItemRow(_ item: TrainingTimelineItem) -> some View {
        switch item {
        case .scheduledPlan(let plan):
            if isPastDue(plan) {
                if let feedback = existingFeedback(for: plan.plan.id) {
                    // Already checked in — show reason and action
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            ScheduledWorkoutRow(scheduled: plan, isMissed: true)
                            workoutStructureHint(plan)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(feedback.reason.emoji) \(feedback.reason.label)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(feedback.action.label)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding()
                    .innerCardStyle(tint: .orange)
                } else {
                    // No feedback yet — tap opens feedback sheet
                    let missedInfo = missedWorkoutDetector.missedInfo(for: plan.plan.id) ?? MissedWorkoutInfo(
                        id: plan.plan.id,
                        displayName: workoutDisplayName(for: plan),
                        scheduledDate: Calendar.current.date(from: plan.date) ?? Date()
                    )
                    Button {
                        feedbackWorkout = missedInfo
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                ScheduledWorkoutRow(scheduled: plan, isMissed: true)
                                workoutStructureHint(plan)
                            }
                            Spacer()
                            Text("Check in")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                        .padding()
                        .innerCardStyle(tint: .orange)
                    }
                    .buttonStyle(.plain)
                }
            } else if plan.complete {
                // Completed scheduled workout — show actual metrics if available
                let matched = matchedWorkout(for: plan)
                NavigationLink {
                    if let summary = matched {
                        WorkoutDetailView(
                            summary: summary,
                            workoutManager: workoutManager
                        )
                    } else {
                        ScheduledWorkoutDetailView(scheduled: plan)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            ScheduledWorkoutRow(scheduled: plan)
                            if let summary = matched {
                                completedWorkoutMetrics(summary)
                            } else {
                                workoutStructureHint(plan)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .innerCardStyle(tint: .green)
                }
                .buttonStyle(.plain)
            } else {
                // Upcoming scheduled workout — navigate to detail
                NavigationLink {
                    ScheduledWorkoutDetailView(scheduled: plan)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            ScheduledWorkoutRow(scheduled: plan)
                            workoutStructureHint(plan)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .innerCardStyle()
                }
                .buttonStyle(.plain)
            }
        case .strengthSession(let entry):
            // Display-only Hevy session. When completed, link through to the
            // matching HealthKit strength workout (hidden from the raw list).
            if entry.completed, let matched = matchedStrengthWorkout(for: entry) {
                NavigationLink {
                    WorkoutDetailView(
                        summary: matched,
                        workoutManager: workoutManager
                    )
                } label: {
                    HStack {
                        StrengthSessionRow(entry: entry)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding()
                    .innerCardStyle(tint: .green)
                }
                .buttonStyle(.plain)
            } else {
                StrengthSessionRow(entry: entry)
                    .padding()
                    .innerCardStyle(tint: entry.completed ? .green : nil)
            }
        case .pastWorkout(let summary):
            NavigationLink {
                WorkoutDetailView(
                    summary: summary,
                    workoutManager: workoutManager
                )
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        WorkoutRow(
                            summary: summary,
                            status: workoutManager.extractionStatuses[summary.id]
                        )
                        pastWorkoutMetrics(summary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .innerCardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Workout Display Name

    private func workoutDisplayName(for scheduled: ScheduledWorkoutPlan) -> String {
        switch scheduled.plan.workout {
        case .custom(let custom):
            return custom.displayName ?? "Custom Workout"
        case .goal(let goal):
            return "Goal: \(goal.activity.displayName)"
        case .pacer(let pacer):
            return "Pacer: \(pacer.activity.displayName)"
        case .swimBikeRun:
            return "Swim-Bike-Run"
        @unknown default:
            return "Workout"
        }
    }

    // MARK: - Scheduled Workout Hint

    @ViewBuilder
    private func workoutStructureHint(_ plan: ScheduledWorkoutPlan) -> some View {
        if case .custom(let custom) = plan.plan.workout {
            let parts = buildStructureParts(custom)
            if !parts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(parts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 40)
            }
        }
    }

    private func buildStructureParts(_ custom: CustomWorkout) -> [String] {
        var parts: [String] = []
        if custom.warmup != nil { parts.append("Warmup") }
        for block in custom.blocks {
            let stepCount = block.steps.count
            if block.iterations > 1 {
                parts.append("\(block.iterations)x \(stepCount) steps")
            } else {
                parts.append("\(stepCount) step\(stepCount == 1 ? "" : "s")")
            }
        }
        if custom.cooldown != nil { parts.append("Cooldown") }
        return parts
    }

    // MARK: - Completed Plan Metrics

    @ViewBuilder
    private func completedWorkoutMetrics(_ summary: WorkoutSummary) -> some View {
        HStack(spacing: 12) {
            if let distance = summary.distance, distance > 0 {
                Label(formatDistance(distance), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label(formatDuration(summary.duration), systemImage: "timer")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let distance = summary.distance, distance > 0 {
                Label(formatPace(duration: summary.duration, distance: distance), systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 40)
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000)
        }
        return "\(Int(meters)) m"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if mins >= 60 {
            let hours = mins / 60
            let remainMins = mins % 60
            return "\(hours)h \(remainMins)m"
        }
        return "\(mins):\(String(format: "%02d", secs))"
    }

    // MARK: - Past Workout Metrics

    @ViewBuilder
    private func pastWorkoutMetrics(_ summary: WorkoutSummary) -> some View {
        if let distance = summary.distance, distance > 0 {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Pace: \(formatPace(duration: summary.duration, distance: distance))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 40)
        }
    }

    private func formatPace(duration: TimeInterval, distance: Double) -> String {
        guard distance > 0 else { return "--" }
        let paceSecondsPerKm = duration / (distance / 1000)
        let minutes = Int(paceSecondsPerKm) / 60
        let seconds = Int(paceSecondsPerKm) % 60
        return "\(minutes):\(String(format: "%02d", seconds)) /km"
    }
}
