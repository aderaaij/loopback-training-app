//
//  RescheduleDatePicker.swift
//  OpenHealthSync
//
//  Lightweight date picker shown when the user taps "Reschedule" in the
//  missed workout feedback sheet. Shows a horizontal week view with
//  existing workout dots, and warns if the selected day already has a workout.
//

import SwiftUI
import WorkoutKit

struct RescheduleDatePicker: View {
    let workout: MissedWorkoutInfo
    let onConfirm: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(WorkoutScheduleManager.self) private var scheduleManager

    @State private var selectedDate: Date = {
        // Default to tomorrow
        Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }()
    @State private var showCollisionWarning = false

    private let calendar = Calendar.current

    /// Dates for the next 14 days starting from today.
    private var availableDates: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// Map of day components to scheduled workout names for collision detection.
    private var scheduledByDay: [DateComponents: [String]] {
        var result: [DateComponents: [String]] = [:]
        for scheduled in scheduleManager.scheduledWorkouts {
            guard !scheduled.complete else { continue }
            let dc = calendar.dateComponents([.year, .month, .day], from:
                calendar.date(from: scheduled.date) ?? .distantPast)
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
            result[dc, default: []].append(name)
        }
        return result
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
                            hasWorkout: workoutsOnDay(date) != nil
                        )
                        .onTapGesture {
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
                        Text("You already have \(existingWorkouts.joined(separator: ", ")) on this day. Schedule both?")
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

                // Confirm button
                Button {
                    onConfirm(selectedDate)
                    dismiss()
                } label: {
                    Text("Confirm")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
        .presentationDetents([.medium])
    }

    private func workoutsOnDay(_ date: Date) -> [String]? {
        let dc = calendar.dateComponents([.year, .month, .day], from: date)
        guard let names = scheduledByDay[dc], !names.isEmpty else { return nil }
        return names
    }
}

// MARK: - Day Cell

private struct RescheduleDayCell: View {
    let date: Date
    let isToday: Bool
    let isSelected: Bool
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
    }
}

// MARK: - Preview

#Preview("Reschedule Picker") {
    let workout = MissedWorkoutInfo(
        id: UUID(),
        displayName: "Tempo Run",
        scheduledDate: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    )

    RescheduleDatePicker(workout: workout) { newDate in
        print("Rescheduled to \(newDate)")
    }
    .environment(WorkoutScheduleManager(apiClient: WorkoutAPIClient()))
}
