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
    @ObservedObject var scheduleManager: WorkoutScheduleManager

    private func plans(_ lifecycle: PlanLifecycle) -> [TrainingPlan] {
        let matching = scheduleManager.allPlans.filter { $0.lifecycle == lifecycle }
        switch lifecycle {
        case .current, .upcoming:
            // Soonest first.
            return matching.sorted { startKey($0) < startKey($1) }
        case .archived:
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
            section(for: .archived)
        }
        .navigationTitle("Plans")
        .navigationBarTitleDisplayMode(.inline)
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
            Section(lifecycle.label) {
                ForEach(group) { plan in
                    NavigationLink {
                        PlanDetailView(plan: plan, scheduleManager: scheduleManager)
                    } label: {
                        PlanRow(plan: plan)
                    }
                }
            }
        }
    }
}

// MARK: - Row

struct PlanRow: View {
    let plan: TrainingPlan

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: PlanFormat.icon(for: plan.activityType))
                .font(.title3)
                .foregroundStyle(plan.isStrength ? LB.violet : LB.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let dateRange = PlanFormat.dateRange(plan) {
                    Text(dateRange)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(trailingDetail)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
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
        case .archived:
            if let total = plan.totalWeeks {
                return "\(total) wk"
            }
            return "Archived"
        }
    }
}

// MARK: - Detail

struct PlanDetailView: View {
    let plan: TrainingPlan
    @ObservedObject var scheduleManager: WorkoutScheduleManager

    @State private var workouts: [PlanWorkout] = []
    @State private var isLoading = true
    @State private var planSchedule: PlanScheduleResponse?

    private var sortedWorkouts: [PlanWorkout] {
        workouts.sorted { ($0.scheduledDate ?? .distantFuture) < ($1.scheduledDate ?? .distantFuture) }
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
                Section("Goals") {
                    ForEach(Array(goals.enumerated()), id: \.offset) { _, goal in
                        GoalRow(goal: goal)
                    }
                }
            }

            if let schedule = planSchedule?.schedule ?? plan.metadata?.schedule {
                Section {
                    ForEach(schedule.orderedDays, id: \.weekday) { day in
                        CadenceRow(weekday: day.weekday, routine: day.routine)
                    }
                } header: {
                    Text("Weekly Cadence")
                } footer: {
                    if let horizonText {
                        Text(horizonText)
                    }
                }
            }

            if let sessions = planSchedule?.sessions, !sessions.isEmpty {
                Section("Sessions (\(sessions.count))") {
                    ForEach(sessions) { session in
                        ScheduleSessionRow(session: session)
                    }
                }
            }

            if isLoading {
                Section {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Loading workouts…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !sortedWorkouts.isEmpty {
                Section("Workouts (\(sortedWorkouts.count))") {
                    ForEach(sortedWorkouts) { workout in
                        PlanWorkoutRow(workout: workout)
                    }
                }
            }

            if let background = plan.metadata?.background, !background.isEmpty {
                Section("Background") {
                    Text(background)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(plan.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
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
                .foregroundStyle(.blue)
            Text(text)
                .font(.subheadline)
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
            Text(weekday.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Image(systemName: "dumbbell.fill")
                .font(.caption)
                .foregroundStyle(LB.violet)
            Text(routine.title)
                .font(.subheadline)
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
                .foregroundStyle(isPast ? Color.secondary.opacity(0.4) : LB.violet)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.subheadline)
                    .foregroundStyle(isPast ? .secondary : .primary)
                if let day = session.day {
                    Text(PlanFormat.medium.string(from: day))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.conflict {
                    let overlaps = session.conflictsWith?.joined(separator: ", ")
                    Label(
                        overlaps.map { "Overlaps \($0)" } ?? "Overlaps a scheduled run",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
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
                .foregroundStyle(isCompleted ? Color.green : Color.secondary.opacity(0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.title)
                    .font(.subheadline)
                    .foregroundStyle(isCompleted ? .primary : .secondary)
                if let date = workout.scheduledDate {
                    Text(PlanFormat.medium.string(from: date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
