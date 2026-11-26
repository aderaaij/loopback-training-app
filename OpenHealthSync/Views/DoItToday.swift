//
//  DoItToday.swift
//  OpenHealthSync
//
//  Brings a run that is planned for a later day forward to today, in one
//  step and without asking why: doing a run early is no setback to explain.
//  The same move can be made from "Change plans", which asks for a reason
//  and a day. Doing it this way keeps the structured session on the watch
//  for the day it is actually run.
//
//  Set the bound run to start. When today already has a run, the athlete
//  chooses between skipping that one and keeping both, as in the reschedule
//  picker.
//

import SwiftUI
import SwiftData
import os

extension View {
    /// Moves the bound run to today as soon as it is set; the binding is
    /// cleared straight away. `onMoved` runs once the run is on today.
    func doItToday(_ workout: Binding<MissedWorkoutInfo?>, onMoved: @escaping () -> Void = {}) -> some View {
        modifier(DoItTodayModifier(workout: workout, onMoved: onMoved))
    }
}

private struct DoItTodayModifier: ViewModifier {
    @Binding var workout: MissedWorkoutInfo?
    let onMoved: () -> Void

    @Environment(WorkoutScheduleManager.self) private var scheduleManager
    @Environment(\.modelContext) private var modelContext

    private struct Notice {
        let title: String
        let message: String
        /// The run did move, so the caller still hears about it.
        let moved: Bool
    }

    /// The run being moved. The binding only starts things off and is
    /// cleared at once, so it can be set again however a dialog was left.
    @State private var pending: MissedWorkoutInfo?
    /// Today's other runs, while the athlete decides what happens to them.
    @State private var inTheWay: [MissedWorkoutInfo] = []
    @State private var isAsking = false
    @State private var isSaving = false
    @State private var notice: Notice?

    func body(content: Content) -> some View {
        content
            .disabled(isSaving)
            .overlay {
                if isSaving {
                    ProgressView()
                        .controlSize(.large)
                        .tint(LB.accent)
                }
            }
            .onChange(of: workout?.id) { _, id in
                if id != nil { begin() }
            }
            // An alert and not a confirmation dialog: that one points at the
            // view it hangs from, and from a long-press menu there is no row
            // left to point at.
            .alert("You already have \(names(inTheWay)) today.", isPresented: $isAsking) {
                Button("Move & skip \(names(inTheWay))") { move(skipping: inTheWay) }
                Button("Keep both") { move(skipping: []) }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                notice?.title ?? "",
                isPresented: Binding(
                    get: { notice != nil },
                    set: { shown in
                        guard !shown, let dismissed = notice else { return }
                        notice = nil
                        if dismissed.moved { onMoved() }
                    }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(notice?.message ?? "")
            }
    }

    private func names(_ workouts: [MissedWorkoutInfo]) -> String {
        workouts.map(\.displayName).joined(separator: ", ")
    }

    private func begin() {
        guard let workout, !isSaving else { return }
        self.workout = nil
        pending = workout
        inTheWay = scheduleManager.openSessions(on: Date(), otherThan: workout.id)
        if inTheWay.isEmpty {
            move(skipping: [])
        } else {
            isAsking = true
        }
    }

    /// Server first, like any change to a run that isn't due yet: until the
    /// server knows, the restore pass would put the run back on its old day.
    private func move(skipping others: [MissedWorkoutInfo]) {
        guard let workout = pending else { return }
        let newDate = workout.time(on: Date())
        // The server takes a reason from a fixed list, and none of them is
        // "I felt like it sooner". The note says what happened.
        let feedback = WorkoutFeedback(
            workoutId: workout.id,
            workoutName: workout.displayName,
            scheduledDate: workout.scheduledDate,
            reason: .other,
            action: .move,
            reasonNote: "Brought forward to do today",
            newDate: newDate
        )
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await scheduleManager.moveUpcomingWorkout(feedback.payload, to: newDate)
            } catch {
                AppLog.scheduling.error("Failed to bring workout \(workout.id, privacy: .public) forward: \(String(describing: error), privacy: .public)")
                notice = Notice(
                    title: "Couldn't move it",
                    message: MissedWorkoutFeedbackSheet.unsavedMessage,
                    moved: false
                )
                return
            }
            feedback.synced = true
            modelContext.insert(feedback)

            let stillOn = await scheduleManager.skipToMakeRoom(others, for: workout, modelContext: modelContext)
            Task { await scheduleManager.refreshAfterPlanChange() }
            if stillOn.isEmpty {
                onMoved()
            } else {
                notice = Notice(
                    title: "Moved, but not everything",
                    message: MissedWorkoutFeedbackSheet.partialMoveMessage(moved: workout, stillOn: stillOn),
                    moved: true
                )
            }
        }
    }
}
