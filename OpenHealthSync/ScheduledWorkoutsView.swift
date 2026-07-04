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
    @ObservedObject var scheduleManager: WorkoutScheduleManager
    @ObservedObject var workoutManager: WorkoutManager
    @ObservedObject var missedWorkoutDetector: MissedWorkoutDetector
    @Environment(\.modelContext) private var modelContext
    @State private var viewMode: ViewMode = .timeline
    @State private var selectedDate: Date?
    @State private var feedbackWorkout: MissedWorkoutInfo?
    @State private var pastWorkoutsLimit = 10

    enum ViewMode: String, CaseIterable {
        case timeline, list
    }

    private var isSyncing: Bool {
        switch scheduleManager.refreshState {
        case .syncing, .scheduling: true
        default: false
        }
    }

    private var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
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

    /// Upcoming display-only strength sessions from the unified calendar.
    private var upcomingStrengthSessions: [CalendarEntry] {
        scheduleManager.calendarEntries
            .filter { $0.kind == .strength && !$0.completed && ($0.day ?? .distantPast) >= startOfToday }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        Group {
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
                        Section {
                            MissedWorkoutBanner(detector: missedWorkoutDetector)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }

                    if let plan = scheduleManager.activePlan {
                        Section {
                            PlanOverviewCard(
                                plan: plan,
                                planWorkouts: scheduleManager.planWorkouts,
                                scheduledWorkouts: scheduleManager.scheduledWorkouts
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } else if scheduleManager.isLoadingPlan {
                        Section {
                            PlanLoadingPlaceholder()
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }

                    if !missedWorkoutsInList.isEmpty {
                        Section("Missed") {
                            ForEach(missedWorkoutsInList, id: \.self) { scheduled in
                                if let feedback = existingFeedback(for: scheduled.plan.id) {
                                    // Already checked in — show reason and action
                                    HStack {
                                        ScheduledWorkoutRow(scheduled: scheduled, isMissed: true)
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text("\(feedback.reason.emoji) \(feedback.reason.label)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(feedback.action.label)
                                                .font(.caption.weight(.medium))
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
                                        feedbackWorkout = MissedWorkoutInfo(
                                            id: scheduled.plan.id,
                                            displayName: workoutDisplayName(for: scheduled),
                                            scheduledDate: Calendar.current.date(from: scheduled.date) ?? Date()
                                        )
                                    } label: {
                                        ScheduledWorkoutRow(scheduled: scheduled, isMissed: true)
                                    }
                                }
                            }
                        }
                    }

                    if let strengthPlan = scheduleManager.activeStrengthPlan {
                        Section {
                            StrengthCycleCard(plan: strengthPlan, scheduleManager: scheduleManager)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }

                    if !upcomingWorkouts.isEmpty {
                        Section("Upcoming Workouts") {
                            ForEach(upcomingWorkouts, id: \.self) { scheduled in
                                NavigationLink {
                                    ScheduledWorkoutDetailView(scheduled: scheduled)
                                } label: {
                                    ScheduledWorkoutRow(scheduled: scheduled)
                                }
                            }
                        }
                    }

                    // Display-only Hevy sessions — never enqueued to the watch.
                    if !upcomingStrengthSessions.isEmpty {
                        Section("Strength Sessions") {
                            ForEach(upcomingStrengthSessions) { entry in
                                StrengthSessionRow(entry: entry, showsDate: true)
                            }
                        }
                    }

                    if !completedWorkouts.isEmpty {
                        Section("Completed Workouts") {
                            ForEach(completedWorkouts, id: \.self) { scheduled in
                                NavigationLink {
                                    ScheduledWorkoutDetailView(scheduled: scheduled)
                                } label: {
                                    ScheduledWorkoutRow(scheduled: scheduled)
                                }
                            }
                        }
                    }

                    if !pastWorkouts.isEmpty {
                        Section("Past Workouts") {
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
                                Button {
                                    pastWorkoutsLimit += 10
                                } label: {
                                    Text("Show More (\(pastWorkouts.count - pastWorkoutsLimit) remaining)")
                                        .font(.subheadline)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                    }
                }
                .lbList()
            }
        }
        .navigationTitle("Training")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    Task {
                        await scheduleManager.refreshFromServer(modelContext: modelContext)
                    }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(isSyncing)
            }
            ToolbarItem(placement: .principal) {
                Picker("View Mode", selection: $viewMode) {
                    Image(systemName: "calendar").tag(ViewMode.timeline)
                    Image(systemName: "list.bullet").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    PlansListView(scheduleManager: scheduleManager)
                } label: {
                    Image(systemName: "calendar.badge.clock")
                }
            }
        }
        .sheet(item: $feedbackWorkout) { workout in
            MissedWorkoutFeedbackFlow(
                missedWorkouts: [workout],
                detector: missedWorkoutDetector
            )
        }
        .task {
            await scheduleManager.loadScheduledWorkouts()
            workoutManager.fetchAllRecentWorkouts()
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

    private func existingFeedback(for workoutId: UUID) -> WorkoutFeedback? {
        let descriptor = FetchDescriptor<WorkoutFeedback>()
        guard let allFeedback = try? modelContext.fetch(descriptor) else { return nil }
        return allFeedback.first { $0.workoutId == workoutId && !$0.dismissed }
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
        HStack(spacing: 13) {
            Image(systemName: isMissed ? "exclamationmark.triangle.fill" : "applewatch")
                .font(.system(size: 20))
                .foregroundStyle(isMissed ? LB.amber : LB.blue)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LB.surfaceTile)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(workoutName)
                    .font(.lbDisplay(15, .semibold))
                    .foregroundStyle(LB.textPrimary)
                if let dateString = formattedDate {
                    Text(dateString)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }

            Spacer()

            if scheduled.complete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LB.green)
            }
        }
        .padding(.vertical, 2)
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
