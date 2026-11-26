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

    /// The day the run already sits on. Only reachable for a run that isn't
    /// due yet (a missed run's day is in the past), and moving it there
    /// changes nothing.
    private func isCurrentDay(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: workout.scheduledDate)
    }

    /// The picked day at the run's original time of day.
    private var newDate: Date {
        workout.time(on: selectedDate)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: LB.Space.xl) {
                // Header
                VStack(spacing: LB.Space.xs) {
                    Text("Reschedule \(workout.displayName)")
                        .font(.lbDisplay(.subheadline, .semibold))
                    Text("Pick a new day")
                        .font(.lbBody(.body))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, LB.Space.lg)

                // Date grid — 2 rows of 7 days
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: LB.Space.xs), count: 7), spacing: LB.Space.sm) {
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
                .padding(.horizontal, LB.Space.lg)

                // Collision warning
                if let existingWorkouts = workoutsOnDay(selectedDate) {
                    HStack(spacing: LB.Space.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.lbBody(.secondary))
                        Text("You already have \(names(existingWorkouts)) on this day.")
                            .font(.lbBody(.secondary))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, LB.Space.lg)
                    .padding(.vertical, LB.Space.sm)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous))
                    .padding(.horizontal, LB.Space.lg)
                }

                Spacer()

                // Confirm buttons
                VStack(spacing: LB.Space.sm) {
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
                .padding(.horizontal, LB.Space.lg)
                .padding(.bottom, LB.Space.lg)
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
                .font(.lbBody(.body, .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .disabled(isCurrentDay(selectedDate))
    }

    /// The runs still to do on that day, other than the one being moved.
    private func workoutsOnDay(_ date: Date) -> [MissedWorkoutInfo]? {
        let workouts = scheduleManager.openSessions(on: date, otherThan: workout.id)
        return workouts.isEmpty ? nil : workouts
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
        VStack(spacing: LB.Space.xxs) {
            Text(date, format: .dateTime.weekday(.narrow))
                .font(.lbBody(.caption))
                .foregroundStyle(isSelected ? .white : .secondary)

            Text("\(Calendar.current.component(.day, from: date))")
                .font(.lbBody(.body))
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
        .padding(.vertical, LB.Space.sm)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: LB.Radius.inner)
                    .fill(Color.accentColor)
            } else if isToday {
                RoundedRectangle(cornerRadius: LB.Radius.inner)
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
