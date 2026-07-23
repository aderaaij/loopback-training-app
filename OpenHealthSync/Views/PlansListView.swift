//
//  PlansListView.swift
//  OpenHealthSync
//
//  Browses every training plan grouped into Current, Upcoming, and Archived,
//  with a tappable detail view per plan.
//

import SwiftUI
import WorkoutKit

struct PlansListView: View {
    var scheduleManager: WorkoutScheduleManager

    private func plans(_ lifecycle: PlanLifecycle) -> [TrainingPlan] {
        let matching = scheduleManager.allPlans.filter { $0.lifecycle == lifecycle }
        switch lifecycle {
        case .current, .upcoming:
            // Soonest first.
            return matching.sorted { startKey($0) < startKey($1) }
        case .completed, .archived:
            // Most recently ended first (fall back to start date when open-ended).
            return matching.sorted { endKey($0) > endKey($1) }
        }
    }

    private func startKey(_ plan: TrainingPlan) -> Date {
        plan.start ?? Date.distantFuture
    }

    private func endKey(_ plan: TrainingPlan) -> Date {
        plan.end ?? plan.start ?? Date.distantPast
    }

    var body: some View {
        List {
            section(for: .current)
            section(for: .upcoming)
            section(for: .completed)
            section(for: .archived)
        }
        .lbList()
        .navigationTitle("Plans")
        .task {
            if scheduleManager.allPlans.isEmpty {
                await scheduleManager.loadAllPlans()
            }
        }
        .refreshable {
            await scheduleManager.loadAllPlans()
        }
        .overlay {
            if scheduleManager.allPlans.isEmpty {
                if scheduleManager.isLoadingPlans {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No Plans",
                        systemImage: "calendar.badge.clock",
                        description: Text("Training plans you create will appear here.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func section(for lifecycle: PlanLifecycle) -> some View {
        let group = plans(lifecycle)
        if !group.isEmpty {
            Section {
                ForEach(group) { plan in
                    NavigationLink {
                        PlanDetailView(plan: plan, scheduleManager: scheduleManager)
                    } label: {
                        PlanRow(plan: plan)
                    }
                }
            } header: {
                LBSectionHeader(title: lifecycle.label)
            }
            .listRowBackground(LB.surface)
        }
    }
}

// MARK: - Row

struct PlanRow: View {
    let plan: TrainingPlan

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: PlanFormat.icon(for: plan.activityType))
                .font(.system(size: 18))
                .foregroundStyle(plan.isStrength ? LB.violet : LB.blue)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LB.surfaceTile)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(plan.name)
                    .font(.lbDisplay(15, .semibold))
                    .foregroundStyle(LB.textPrimary)
                    .lineLimit(1)
                if let dateRange = PlanFormat.dateRange(plan) {
                    Text(dateRange)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }

            Spacer()

            LBStatusChip(text: trailingDetail, color: chipColor)
        }
        .padding(.vertical, 2)
    }

    private var trailingDetail: String {
        switch plan.lifecycle {
        case .current:
            if let week = plan.currentWeek, let total = plan.totalWeeks {
                return "Week \(week + 1)/\(total)"
            }
            return "Current"
        case .upcoming:
            if let start = plan.start {
                return "Starts \(PlanFormat.short.string(from: start))"
            }
            return "Upcoming"
        case .completed:
            if let progress = plan.progress, progress.runsTotal > 0 {
                return "\(progress.runsCompleted)/\(progress.runsTotal) done"
            }
            return "Done"
        case .archived:
            if let total = plan.totalWeeks {
                return "\(total) wk"
            }
            return "Archived"
        }
    }

    private var chipColor: Color {
        switch plan.lifecycle {
        case .current: LB.accent
        case .upcoming: LB.blue
        case .completed: LB.green
        case .archived: LB.textMuted
        }
    }
}

// MARK: - Detail

struct PlanDetailView: View {
    let plan: TrainingPlan
    var scheduleManager: WorkoutScheduleManager

    @State private var workouts: [PlanWorkout] = []
    @State private var isLoading = true
    @State private var planSchedule: PlanScheduleResponse?

    private var sortedWorkouts: [PlanWorkout] {
        workouts.sorted { ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture) }
    }

    private func scheduledPlan(for workout: PlanWorkout) -> ScheduledWorkoutPlan? {
        scheduleManager.scheduledWorkouts.first { $0.plan.id == workout.id }
    }

    /// Footer for the cadence section: the cycle horizon, cueing when it's
    /// time to plan the next block.
    private var horizonText: String? {
        guard let end = plan.end, let days = plan.daysRemaining else { return nil }
        let endString = PlanFormat.medium.string(from: end)
        if days < 0 {
            return "Cycle ended \(endString) — time to plan the next one."
        } else if days == 0 {
            return "Cycle ends today."
        }
        return "Cycle ends \(endString) · \(days) day\(days == 1 ? "" : "s") left."
    }

    var body: some View {
        List {
            Section {
                PlanOverviewCard(
                    plan: plan,
                    planWorkouts: workouts,
                    scheduledWorkouts: scheduleManager.scheduledWorkouts
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if let goals = plan.metadata?.goals, !goals.isEmpty {
                Section {
                    ForEach(Array(goals.enumerated()), id: \.offset) { _, goal in
                        GoalRow(goal: goal)
                    }
                } header: {
                    LBSectionHeader(title: "Goals")
                }
                .listRowBackground(LB.surface)
            }

            if let schedule = planSchedule?.schedule ?? plan.metadata?.schedule {
                Section {
                    ForEach(schedule.orderedDays, id: \.weekday) { day in
                        CadenceRow(weekday: day.weekday, routine: day.routine)
                    }
                } header: {
                    LBSectionHeader(title: "Weekly Cadence")
                } footer: {
                    if let horizonText {
                        Text(horizonText)
                    }
                }
                .listRowBackground(LB.surface)
            }

            if let sessions = planSchedule?.sessions, !sessions.isEmpty {
                Section {
                    ForEach(sessions) { session in
                        ScheduleSessionRow(session: session)
                    }
                } header: {
                    LBSectionHeader(title: "Sessions (\(sessions.count))")
                }
                .listRowBackground(LB.surface)
            }

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading workouts…")
                            .font(.lbBody(13))
                            .foregroundStyle(LB.textSecondary)
                    }
                }
                .listRowBackground(LB.surface)
            } else if !sortedWorkouts.isEmpty {
                Section {
                    ForEach(sortedWorkouts) { workout in
                        // Only rows still present in the WorkoutKit scheduler
                        // have a structured detail to open; the rest render
                        // plain (no disclosure chevron).
                        if let scheduled = scheduledPlan(for: workout) {
                            NavigationLink {
                                ScheduledWorkoutDetailView(scheduled: scheduled)
                            } label: {
                                PlanWorkoutRow(workout: workout)
                            }
                        } else {
                            PlanWorkoutRow(workout: workout)
                        }
                    }
                } header: {
                    LBSectionHeader(title: "Workouts (\(sortedWorkouts.count))")
                }
                .listRowBackground(LB.surface)
            }

            if let background = plan.metadata?.background, !background.isEmpty {
                Section {
                    Text(background)
                        .font(.lbBody(13))
                        .foregroundStyle(LB.textSecondary)
                } header: {
                    LBSectionHeader(title: "Background")
                }
                .listRowBackground(LB.surface)
            }
        }
        .lbList()
        .navigationTitle(plan.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The WorkoutKit scheduler backs the per-workout links; make sure
            // it's loaded even when Plans is the first tab visited.
            if scheduleManager.scheduledWorkouts.isEmpty {
                await scheduleManager.loadScheduledWorkouts()
            }

            // Reuse already-loaded workouts when viewing the active plan.
            if plan.id == scheduleManager.activePlan?.id, !scheduleManager.planWorkouts.isEmpty {
                workouts = scheduleManager.planWorkouts
                isLoading = false
            } else {
                workouts = await scheduleManager.workouts(forPlan: plan.id)
                isLoading = false
            }

            // Expand the cadence to dated sessions (with conflict warnings)
            // for plans that carry one.
            if plan.isStrength || plan.metadata?.schedule != nil {
                planSchedule = await scheduleManager.schedule(forPlan: plan.id)
            }
        }
    }
}

// MARK: - Detail Rows

private struct GoalRow: View {
    let goal: PlanGoal

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "target")
                .font(.caption)
                .foregroundStyle(LB.blue)
            Text(text)
                .font(.lbBody(13, .medium))
                .foregroundStyle(LB.textPrimary)
            Spacer()
        }
    }

    private var text: String {
        if let description = goal.description, !description.isEmpty {
            return description
        }
        var parts = [goal.type.replacingOccurrences(of: "_", with: " ").capitalized]
        if let target = goal.target {
            parts.append([target.displayString, goal.unit].compactMap { $0 }.joined(separator: " "))
        }
        if let byWeek = goal.byWeek {
            parts.append("by week \(byWeek + 1)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct CadenceRow: View {
    let weekday: String
    let routine: RoutineRef

    var body: some View {
        HStack(spacing: 10) {
            Text(weekday.prefix(3).uppercased())
                .font(.lbMono(11, .semibold))
                .foregroundStyle(LB.textTertiary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: "dumbbell.fill")
                .font(.caption)
                .foregroundStyle(LB.violet)
            Text(routine.title)
                .font(.lbBody(13, .medium))
                .foregroundStyle(LB.textPrimary)
            Spacer()
        }
    }
}

private struct ScheduleSessionRow: View {
    let session: ScheduleSession

    private var isPast: Bool {
        guard let day = session.day else { return false }
        return day < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dumbbell.fill")
                .font(.caption)
                .foregroundStyle(isPast ? LB.textFaint : LB.violet)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.lbBody(13, .medium))
                    .foregroundStyle(isPast ? LB.textTertiary : LB.textPrimary)
                if let day = session.day {
                    Text(PlanFormat.medium.string(from: day))
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
                if session.conflict {
                    let overlaps = session.conflictsWith?.joined(separator: ", ")
                    Label(
                        overlaps.map { "Overlaps \($0)" } ?? "Overlaps a scheduled run",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.lbBody(11))
                    .foregroundStyle(LB.amber)
                }
            }
            Spacer()
        }
        .padding(.vertical, 1)
    }
}

private struct PlanWorkoutRow: View {
    let workout: PlanWorkout

    private var isCompleted: Bool { workout.status == "completed" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCompleted ? LB.green : LB.textFaint)
            VStack(alignment: .leading, spacing: 3) {
                Text(workout.title)
                    .font(.lbBody(13, .medium))
                    .foregroundStyle(isCompleted ? LB.textPrimary : LB.textSecondary)
                if let date = workout.scheduledDate {
                    Text(PlanFormat.medium.string(from: date))
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Formatting Helpers

enum PlanFormat {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    static func dateRange(_ plan: TrainingPlan) -> String? {
        if let start = plan.start, let end = plan.end {
            return "\(short.string(from: start)) – \(short.string(from: end))"
        }
        if let start = plan.start {
            return "From \(short.string(from: start))"
        }
        return nil
    }

    static func icon(for activityType: String) -> String {
        switch activityType.lowercased() {
        case "running", "run": return "figure.run"
        case "cycling", "bike", "biking": return "figure.outdoor.cycle"
        case "swimming", "swim": return "figure.pool.swim"
        case "walking", "walk": return "figure.walk"
        case "hiking", "hike": return "figure.hiking"
        case "strength", "gym", "lifting": return "dumbbell.fill"
        default: return "figure.run.circle"
        }
    }
}
