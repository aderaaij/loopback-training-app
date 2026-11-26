//
//  LinkSessionViews.swift
//  OpenHealthSync
//
//  Counting a recorded workout for a planned session after the fact: the run
//  that was started without the session on the watch, done on another day, or
//  swapped for something else. Two pickers, one from each side: choose the
//  workout for a session (from the check-in sheet), or the session for a
//  workout (from the workout's own screen).
//
//  Nothing has to match. The athlete decides what counts; the coach still
//  sees the workout that was actually done.
//

import SwiftUI
import WorkoutKit
import os

// MARK: - Sessions a workout can count for

/// A planned session that has no workout counted for it yet.
struct LinkableSession: Identifiable {
    enum State {
        case missed, upcoming, skipped, completed

        var label: String {
            switch self {
            case .missed: return "Missed"
            case .upcoming: return "Upcoming"
            case .skipped: return "Skipped"
            case .completed: return "Completed"
            }
        }

        var color: Color {
            switch self {
            case .missed: return LB.amber
            case .upcoming: return LB.blue
            case .skipped: return LB.textMuted
            case .completed: return LB.green
            }
        }
    }

    let id: UUID
    let title: String
    let date: Date?
    let state: State
}

extension WorkoutScheduleManager {
    /// Sessions without a workout, nearest to `date` first: the active plan's
    /// runs, plus anything else on the watch's schedule. A completed session
    /// is listed when no workout is linked to it, which is how the watch
    /// leaves a run it ticked off but the app couldn't match.
    func linkableSessions(near date: Date, limit: Int = 20) -> [LinkableSession] {
        let startOfToday = Calendar.current.startOfDay(for: Date())

        func state(done: Bool, skipped: Bool, on day: Date?) -> LinkableSession.State {
            if done { return .completed }
            if skipped { return .skipped }
            guard let day else { return .upcoming }
            return day < startOfToday ? .missed : .upcoming
        }

        var sessions: [LinkableSession] = []
        var seen: Set<UUID> = []

        for workout in planWorkouts where linkedWorkoutId(forSession: workout.id) == nil {
            let day = workout.scheduledDate ?? scheduledDate(for: workout.id)
            seen.insert(workout.id)
            sessions.append(LinkableSession(
                id: workout.id,
                title: workout.title,
                date: day,
                state: state(done: workout.status == "completed", skipped: workout.status == "skipped", on: day)
            ))
        }

        for scheduled in scheduledWorkouts
        where !seen.contains(scheduled.plan.id) && linkedWorkoutId(forSession: scheduled.plan.id) == nil {
            let day = Calendar.current.date(from: scheduled.date)
            sessions.append(LinkableSession(
                id: scheduled.plan.id,
                title: scheduled.plan.displayTitle,
                date: day,
                state: state(done: scheduled.complete, skipped: false, on: day)
            ))
        }

        func distance(_ session: LinkableSession) -> TimeInterval {
            session.date.map { abs($0.timeIntervalSince(date)) } ?? .greatestFiniteMagnitude
        }
        return Array(sessions.sorted { distance($0) < distance($1) }.prefix(limit))
    }
}

/// What to tell the athlete when a link didn't go through.
private func linkFailureMessage(_ error: Error) -> String {
    if case WorkoutAPIError.serverError(let code) = error, code == 404 || code == 405 {
        return "Couldn't link these. The workout may not have synced yet, or your server needs an update."
    }
    return "Couldn't reach your server, so nothing changed. Try again once you're connected."
}

// MARK: - Pick the session for a workout

struct SessionPickerSheet: View {
    let workout: WorkoutSummary
    /// Called with the workout's new context once the server has linked it.
    let onLinked: (WorkoutContext) -> Void

    @Environment(WorkoutScheduleManager.self) private var scheduleManager
    @Environment(\.dismiss) private var dismiss
    @State private var savingId: UUID?
    @State private var failure: String?

    private var sessions: [LinkableSession] {
        scheduleManager.linkableSessions(near: workout.startDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LB.Space.sm) {
                    if sessions.isEmpty {
                        LinkPickerEmptyState(
                            icon: "calendar",
                            title: "No open sessions",
                            message: "Every planned session already has a workout."
                        )
                    } else {
                        Text("Pick the session this \(workout.activityName.lowercased()) counts for. It doesn't have to be the same day or the same kind of workout.")
                            .font(.lbBody(.secondary))
                            .foregroundStyle(LB.textSecondary)
                            .padding(.bottom, LB.Space.sm)

                        ForEach(sessions) { session in
                            Button {
                                link(to: session)
                            } label: {
                                LinkPickerRow(
                                    icon: "applewatch",
                                    title: session.title,
                                    detail: session.date.map { Self.format($0) } ?? "No date",
                                    chip: (session.state.label, session.state.color),
                                    isSaving: savingId == session.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let failure {
                        Text(failure)
                            .font(.lbBody(.secondary))
                            .foregroundStyle(LB.amber)
                            .padding(.top, LB.Space.xs)
                    }
                }
                .padding(LB.Space.lg)
                .disabled(savingId != nil)
            }
            .background(LB.bg)
            .presentationBackground(LB.bg)
            .presentationDragIndicator(.visible)
            .navigationTitle("Count for a session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(savingId != nil)
                }
            }
        }
    }

    private func link(to session: LinkableSession) {
        savingId = session.id
        failure = nil
        Task {
            defer { savingId = nil }
            do {
                let context = try await scheduleManager.setPlanLink(workoutId: workout.id, sessionId: session.id)
                onLinked(context)
                dismiss()
            } catch {
                AppLog.sync.error("Failed to link workout \(workout.id, privacy: .public): \(String(describing: error), privacy: .public)")
                failure = linkFailureMessage(error)
            }
        }
    }

    private static func format(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

// MARK: - Pick the workout for a session

struct WorkoutPickerSheet: View {
    let session: MissedWorkoutInfo
    let onLinked: () -> Void

    @Environment(WorkoutScheduleManager.self) private var scheduleManager
    @Environment(WorkoutManager.self) private var workoutManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    @State private var savingId: UUID?
    @State private var failure: String?

    /// How far either side of the session's day a workout can be and still
    /// be offered. Wide enough for a week that got shuffled around.
    private static let window: TimeInterval = 21 * 24 * 3600

    /// Workouts near the session's day, nearest first.
    private var workouts: [WorkoutSummary] {
        workoutManager.allWorkouts
            .filter { abs($0.startDate.timeIntervalSince(session.scheduledDate)) <= Self.window }
            .sorted {
                abs($0.startDate.timeIntervalSince(session.scheduledDate))
                    < abs($1.startDate.timeIntervalSince(session.scheduledDate))
            }
    }

    private var linkedWorkoutIds: Set<UUID> {
        Set(scheduleManager.sessionLinks.values)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LB.Space.sm) {
                    if workouts.isEmpty {
                        LinkPickerEmptyState(
                            icon: "figure.run",
                            title: "No workouts around then",
                            message: "Nothing was recorded within three weeks of this session."
                        )
                    } else {
                        Text("Pick the workout that counts for \(session.displayName). It doesn't have to be the same day or the same kind of workout.")
                            .font(.lbBody(.secondary))
                            .foregroundStyle(LB.textSecondary)
                            .padding(.bottom, LB.Space.sm)

                        ForEach(workouts) { workout in
                            Button {
                                link(workout)
                            } label: {
                                LinkPickerRow(
                                    icon: Self.icon(for: workout.activityType),
                                    title: workout.activityName,
                                    detail: detail(workout),
                                    chip: linkedWorkoutIds.contains(workout.id) ? ("Other session", LB.textMuted) : nil,
                                    isSaving: savingId == workout.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if let failure {
                        Text(failure)
                            .font(.lbBody(.secondary))
                            .foregroundStyle(LB.amber)
                            .padding(.top, LB.Space.xs)
                    }
                }
                .padding(LB.Space.lg)
                .disabled(savingId != nil)
            }
            .background(LB.bg)
            .presentationBackground(LB.bg)
            .presentationDragIndicator(.visible)
            .navigationTitle("Pick a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(savingId != nil)
                }
            }
            .onAppear { workoutManager.fetchAllRecentWorkouts() }
        }
    }

    private static func icon(for activityType: String) -> String {
        switch activityType {
        case "running": return "figure.run"
        case "walking": return "figure.walk"
        case "cycling": return "figure.outdoor.cycle"
        case "hiking": return "figure.hiking"
        case "swimming": return "figure.pool.swim"
        case "functionalStrength", "traditionalStrength": return "figure.strengthtraining.functional"
        default: return "figure.mixed.cardio"
        }
    }

    private func detail(_ workout: WorkoutSummary) -> String {
        var parts = [workout.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())]
        if let distance = workout.distance, distance > 0 {
            parts.append(units.distance(meters: distance))
        }
        parts.append("\(Int(workout.duration / 60)) min")
        return parts.joined(separator: " · ")
    }

    private func link(_ workout: WorkoutSummary) {
        savingId = workout.id
        failure = nil
        Task {
            defer { savingId = nil }
            do {
                try await scheduleManager.setPlanLink(workoutId: workout.id, sessionId: session.id)
                dismiss()
                onLinked()
            } catch {
                AppLog.sync.error("Failed to link session \(session.id, privacy: .public): \(String(describing: error), privacy: .public)")
                failure = linkFailureMessage(error)
            }
        }
    }
}

// MARK: - Shared pieces

private struct LinkPickerRow: View {
    let icon: String
    let title: String
    let detail: String
    var chip: (text: String, color: Color)?
    var isSaving = false

    var body: some View {
        HStack(spacing: LB.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 32)
                .foregroundStyle(LB.accent)

            VStack(alignment: .leading, spacing: LB.Space.xs) {
                Text(title)
                    .font(.lbBody(.body, .semibold))
                    .foregroundStyle(LB.textPrimary)
                    .lineLimit(2)
                Text(detail.uppercased())
                    .font(.lbMono(.caption))
                    .foregroundStyle(LB.textTertiary)
            }

            Spacer()

            if isSaving {
                ProgressView().controlSize(.small).tint(LB.accent)
            } else if let chip {
                LBStatusChip(text: chip.text, color: chip.color)
            }
        }
        .padding(LB.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous).fill(LB.optionOff)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous).strokeBorder(LB.line, lineWidth: 1)
        )
    }
}

private struct LinkPickerEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: LB.Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(LB.textMuted)
            Text(title)
                .font(.lbDisplay(.subheadline, .semibold))
                .foregroundStyle(LB.textSecondary)
            Text(message)
                .font(.lbBody(.secondary))
                .foregroundStyle(LB.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
