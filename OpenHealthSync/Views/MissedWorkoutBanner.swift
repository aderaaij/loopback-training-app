//
//  MissedWorkoutBanner.swift
//  OpenHealthSync
//
//  Shows a card/banner on the Training tab when missed workouts
//  are detected. Tapping "Check in" opens the feedback sheet.
//

import SwiftUI
import SwiftData

struct MissedWorkoutBanner: View {
    var detector: MissedWorkoutDetector
    @Environment(WorkoutScheduleManager.self) private var scheduleManager
    @Environment(\.modelContext) private var modelContext

    @State private var showFeedbackSheet = false

    var body: some View {
        if !detector.missedWorkouts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LB.amber)
                        .font(.system(size: 22))

                    VStack(alignment: .leading, spacing: 4) {
                        if detector.missedWorkouts.count == 1, let workout = detector.missedWorkouts.first {
                            Text("You missed \(workout.displayName)")
                                .font(.lbDisplay(15, .semibold))
                                .foregroundStyle(LB.textPrimary)
                            Text(relativeDate(workout.scheduledDate))
                                .font(.lbBody(12))
                                .foregroundStyle(LB.textTertiary)
                        } else {
                            Text("You have \(detector.missedWorkouts.count) missed workouts")
                                .font(.lbDisplay(15, .semibold))
                                .foregroundStyle(LB.textPrimary)
                            Text("Want to check in?")
                                .font(.lbBody(12))
                                .foregroundStyle(LB.textTertiary)
                        }
                    }

                    Spacer()

                    Button {
                        dismissAll()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LB.textMuted)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showFeedbackSheet = true
                } label: {
                    Text("Check in")
                        .font(.lbBody(14, .semibold))
                        .foregroundStyle(LB.bg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(LB.amber)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .cardStyle(tint: LB.amber)
            .padding(.horizontal)
            .sheet(isPresented: $showFeedbackSheet) {
                MissedWorkoutFeedbackFlow(
                    missedWorkouts: detector.missedWorkouts,
                    detector: detector
                )
            }
        }
    }

    private func dismissAll() {
        for workout in detector.missedWorkouts {
            detector.dismiss(workout: workout, modelContext: modelContext)

            // Sync dismissal to training API
            // Fetch the just-inserted feedback to get its ID for sync tracking
            let targetWorkoutId = workout.id
            let descriptor = FetchDescriptor<WorkoutFeedback>(
                predicate: #Predicate<WorkoutFeedback> { feedback in
                    feedback.workoutId == targetWorkoutId && feedback.dismissed == true
                },
                sortBy: [SortDescriptor(\.detectedAt, order: .reverse)]
            )
            if let inserted = try? modelContext.fetch(descriptor).first {
                let payload = WorkoutFeedbackPayload(
                    id: inserted.id,
                    workoutId: inserted.workoutId,
                    workoutName: inserted.workoutName,
                    scheduledDate: inserted.scheduledDate,
                    detectedAt: inserted.detectedAt,
                    acknowledgedAt: inserted.acknowledgedAt,
                    reason: inserted.reason.rawValue,
                    reasonNote: inserted.reasonNote,
                    action: inserted.action.rawValue,
                    newDate: inserted.newDate,
                    dismissed: inserted.dismissed
                )
                scheduleManager.syncFeedback(payload, feedbackId: inserted.id, modelContext: modelContext)
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Scheduled \(formatter.localizedString(for: date, relativeTo: Date()))"
    }
}
