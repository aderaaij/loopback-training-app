//
//  RescheduleDatePicker.swift
//  OpenHealthSync
//
//  Lightweight date picker shown when the user taps "Reschedule" in the
//  missed workout feedback sheet, or moves a run ahead of time. Shows a
//  horizontal week view with existing workout dots, and when the selected day
//  already has a workout, offers to skip that one or keep both.
//

import SwiftUI
import WorkoutKit

struct RescheduleDatePicker: View {
    let workout: MissedWorkoutInfo
    /// The new date, and the runs already on that day to skip to make room.
    let onConfirm: (_ newDate: Date, _ skipping: [MissedWorkoutInfo]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutScheduleManager.self) private var scheduleManager

    @State private var selectedDate: Date

    private let calendar = Calendar.current

    init(workout: MissedWorkoutInfo, onConfirm: @escaping (_ newDate: Date, _ skipping: [MissedWorkoutInfo]) -> Void) {
        self.workout = workout
        self.onConfirm = onConfirm
        // A run that isn't due yet defaults to the day after it; a missed one
        // to tomorrow.
        let from = workout.isUpcoming ? workout.scheduledDate : Date()
        _selectedDate = State(initialValue: Calendar.current.date(byAdding: .day, value: 1, to: from) ?? from)
    }

    /// Dates for the next 14 days starting from today.
    private var availableDates: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// Incomplete workouts per day, other than the one being moved.
    private var scheduledByDay: [DateComponents: [MissedWorkoutInfo]] {
        var result: [DateComponents: [MissedWorkoutInfo]] = [:]
        for scheduled in scheduleManager.scheduledWorkouts {
            guard !scheduled.complete, scheduled.plan.id != workout.id else { continue }
            let date = calendar.date(from: scheduled.date) ?? .distantPast
            let dc = calendar.dateComponents([.year, .month, .day], from: date)
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
            result[dc, default: []].append(
                MissedWorkoutInfo(id: scheduled.plan.id, displayName: name, scheduledDate: date)
            )
        }
        return result
    }

    /// The day the run already sits on. Only reachable for a run that isn't
    /// due yet (a missed run's day is in the past), and moving it there
    /// changes nothing.
    private func isCurrentDay(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: workout.scheduledDate)
    }

    /// The picked day at the run's original time of day. A bare day would be
    /// local midnight, which the server (bucketing by UTC date) files under
    /// the day before anywhere east of UTC.
    private var newDate: Date {
        let time = calendar.dateComponents([.hour, .minute], from: workout.scheduledDate)
        return calendar.date(
            bySettingHour: time.hour ?? 0,
            minute: time.minute ?? 0,
            second: 0,
            of: selectedDate
        ) ?? selectedDate
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Header
                VStack(spacing: 4) {
                    Text("Reschedule \(workout.displayName)")
                        .font(.headline)
                    Text("Pick a new day")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top)

                // Date grid — 2 rows of 7 days
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                    ForEach(availableDates, id: \.self) { date in
                        RescheduleDayCell(
                            date: date,
                            isToday: calendar.isDateInToday(date),
                            isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                            isCurrentDay: isCurrentDay(date),
                            hasWorkout: workoutsOnDay(date) != nil
                        )
                        .onTapGesture {
                            guard !isCurrentDay(date) else { return }
                            selectedDate = date
                        }
                    }
                }
                .padding(.horizontal)

                // Collision warning
                if let existingWorkouts = workoutsOnDay(selectedDate) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("You already have \(names(existingWorkouts)) on this day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                Spacer()

                // Confirm buttons
                VStack(spacing: 10) {
                    if let existingWorkouts = workoutsOnDay(selectedDate) {
                        confirmButton("Move & skip \(names(existingWorkouts))", skipping: existingWorkouts)
                            .buttonStyle(.borderedProminent)
                        confirmButton("Keep both", skipping: [])
                            .buttonStyle(.bordered)
                    } else {
                        confirmButton("Confirm", skipping: [])
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func confirmButton(_ title: String, skipping: [MissedWorkoutInfo]) -> some View {
        Button {
            onConfirm(newDate, skipping)
            dismiss()
        } label: {
            Text(title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .disabled(isCurrentDay(selectedDate))
    }

    private func workoutsOnDay(_ date: Date) -> [MissedWorkoutInfo]? {
        let dc = calendar.dateComponents([.year, .month, .day], from: date)
        guard let workouts = scheduledByDay[dc], !workouts.isEmpty else { return nil }
        return workouts
    }

    private func names(_ workouts: [MissedWorkoutInfo]) -> String {
        workouts.map(\.displayName).joined(separator: ", ")
    }
}

// MARK: - Day Cell

private struct RescheduleDayCell: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
    /// The day the run already sits on — shown, but not pickable.
    let isCurrentDay: Bool
    let hasWorkout: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(date, format: .dateTime.weekday(.narrow))
                .font(.caption2)
                .foregroundStyle(isSelected ? .white : .secondary)

            Text("\(Calendar.current.component(.day, from: date))")
                .font(.subheadline)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(isSelected ? .white : .primary)

            if hasWorkout {
                Circle()
                    .fill(isSelected ? .white : .blue)
                    .frame(width: 5, height: 5)
            } else {
                Circle()
                    .fill(.clear)
                    .frame(width: 5, height: 5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor)
            } else if isToday {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
        .opacity(isCurrentDay ? 0.35 : 1)
    }
}

// MARK: - Preview

#Preview("Reschedule Picker") {
    let workout = MissedWorkoutInfo(
        id: UUID(),
        displayName: "Tempo Run",
        scheduledDate: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    )

    RescheduleDatePicker(workout: workout) { newDate, skipping in
        print("Rescheduled to \(newDate), skipping \(skipping.map(\.displayName))")
    }
    .environment(WorkoutScheduleManager(apiClient: WorkoutAPIClient()))
}
