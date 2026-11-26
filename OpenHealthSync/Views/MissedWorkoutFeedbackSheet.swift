//
//  MissedWorkoutFeedbackSheet.swift
//  OpenHealthSync
//
//  Bottom sheet for collecting feedback when a workout is missed, or when the
//  athlete moves or skips a run before it's due ("Change of plans").
//  Two steps: reason picker (tappable chips) + action picker.
//  Handles multi-miss batching by advancing through the queue.
//

import SwiftUI
import SwiftData
import os

// MARK: - Feedback Flow (multi-workout wrapper)

struct MissedWorkoutFeedbackFlow: View {
    let missedWorkouts: [MissedWorkoutInfo]
    /// Nil when changing an upcoming run, which the detector never lists.
    var detector: MissedWorkoutDetector?
    @Environment(WorkoutScheduleManager.self) private var scheduleManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0

    var body: some View {
        NavigationStack {
            if currentIndex < missedWorkouts.count {
                MissedWorkoutFeedbackSheet(
                    workout: missedWorkouts[currentIndex],
                    currentIndex: currentIndex + 1,
                    totalCount: missedWorkouts.count,
                    scheduleManager: scheduleManager,
                    onComplete: { handledWorkout in
                        // Remove from detector so banner/indicators update immediately
                        detector?.missedWorkouts.removeAll { $0.id == handledWorkout.id }
                        advanceOrDismiss()
                    }
                )
            }
        }
        .interactiveDismissDisabled(false)
    }

    private func advanceOrDismiss() {
        let nextIndex = currentIndex + 1
        if nextIndex < missedWorkouts.count {
            currentIndex = nextIndex
        } else {
            dismiss()
        }
    }
}

// MARK: - Single Workout Feedback Sheet

struct MissedWorkoutFeedbackSheet: View {
    let workout: MissedWorkoutInfo
    let currentIndex: Int
    let totalCount: Int
    let scheduleManager: WorkoutScheduleManager
    let onComplete: (MissedWorkoutInfo) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SetbackStore.self) private var setbackStore

    @State private var selectedReason: MissedWorkoutReason?
    @State private var reasonNote = ""
    @State private var showReschedulePicker = false
    @State private var showWorkoutPicker = false
    @State private var showAdjustConfirmation = false
    /// A change is on its way to the server; the actions are locked meanwhile.
    @State private var isSaving = false
    /// Shown under the actions when the server couldn't be told, so nothing changed.
    @State private var saveError: String?
    /// The move went through but a run it should have made room for is still on.
    @State private var partialFailure: String?

    static let unsavedMessage = "Couldn't reach your server, so nothing changed. Try again once you're connected."

    /// For a move that went through while a run it should have made room for
    /// is still on.
    static func partialMoveMessage(moved: MissedWorkoutInfo, stillOn: [MissedWorkoutInfo]) -> String {
        let names = stillOn.map(\.displayName).joined(separator: ", ")
        return "\(moved.displayName) is on its new day, but \(names) couldn't be skipped because your server was unreachable. You can skip it from its own screen."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection

                // Done after all: no reason to give, so it sits above them.
                actionButton(
                    title: workout.isUpcoming ? "I already did this" : "I did this",
                    subtitle: "Count a workout you recorded for it",
                    icon: "link",
                    style: .secondary
                ) {
                    showWorkoutPicker = true
                }
                .disabled(isSaving)
                .padding(.horizontal)

                // Reason picker
                reasonSection

                // Note: asked for with "Other", optional with sick or injured
                if let reason = selectedReason, reason == .other || reason.setbackKind != nil {
                    TextField(notePrompt(for: reason), text: $reasonNote, axis: .vertical)
                        .font(.lbBody(14))
                        .foregroundStyle(LB.textPrimary)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LB.optionOff)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(LB.line, lineWidth: 1)
                        )
                        .padding(.horizontal)
                }

                if let kind = selectedReason?.setbackKind {
                    Text(setbackExplanation(for: kind))
                        .font(.lbBody(12))
                        .foregroundStyle(LB.textTertiary)
                        .padding(.horizontal)
                }

                // Action buttons
                if selectedReason != nil {
                    actionSection
                }
            }
            .padding(.vertical)
        }
        .background(LB.bg)
        .scrollContentBackground(.hidden)
        .presentationBackground(LB.bg)
        .presentationDragIndicator(.visible)
        .navigationTitle(workout.isUpcoming ? "Change plans" : "Check in")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
        }
        .sheet(isPresented: $showReschedulePicker) {
            RescheduleDatePicker(
                workout: workout,
                onConfirm: { newDate, skipping in
                    move(to: newDate, skipping: skipping)
                }
            )
        }
        .sheet(isPresented: $showWorkoutPicker) {
            WorkoutPickerSheet(session: workout) {
                onComplete(workout)
            }
        }
        .alert(
            "Moved, but not everything",
            isPresented: Binding(
                get: { partialFailure != nil },
                set: { if !$0 { partialFailure = nil } }
            )
        ) {
            Button("OK") { onComplete(workout) }
        } message: {
            Text(partialFailure ?? "")
        }
        .overlay {
            if showAdjustConfirmation {
                adjustConfirmationOverlay
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if totalCount > 1 {
                Text("\(currentIndex) of \(totalCount)")
                    .font(.lbMono(11))
                    .foregroundStyle(LB.textTertiary)
                    .padding(.horizontal)
            }

            HStack(spacing: 12) {
                Image(systemName: workout.isUpcoming ? "calendar.badge.clock" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(workout.isUpcoming ? LB.accent : LB.amber)

                VStack(alignment: .leading, spacing: 3) {
                    Text(workout.isUpcoming ? "Change of plans" : "Missed workout")
                        .font(.lbDisplay(18, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    Text("\(workout.displayName.uppercased()) · \(workout.scheduledDate.formatted(.dateTime.day().month(.abbreviated)).uppercased())")
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Reason Picker

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LBSectionHeader(title: "What happened?")
                .padding(.horizontal)

            FlowLayout(spacing: 9) {
                ForEach(MissedWorkoutReason.allCases) { reason in
                    ReasonChip(
                        reason: reason,
                        isSelected: selectedReason == reason
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedReason = reason
                            if reason != .other && reason.setbackKind == nil {
                                reasonNote = ""
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LBSectionHeader(title: "Then what?")
                .padding(.horizontal)

            VStack(spacing: 9) {
                actionButton(
                    title: "Reschedule",
                    subtitle: "Move to another day",
                    icon: "calendar.badge.clock",
                    style: .prominent
                ) {
                    showReschedulePicker = true
                }

                if workout.isUpcoming {
                    actionButton(
                        title: "Skip this run",
                        subtitle: "Takes it off your watch",
                        icon: "forward.fill",
                        style: .secondary
                    ) {
                        skipUpcoming()
                    }
                } else {
                    actionButton(
                        title: "Adjust plan",
                        subtitle: "We'll bring this up next time you review your plan",
                        icon: "arrow.triangle.branch",
                        style: .secondary
                    ) {
                        saveFeedback(action: .adjust)
                        showAdjustConfirmation = true
                    }

                    actionButton(
                        title: "Skip this one",
                        subtitle: "No changes needed",
                        icon: "forward.fill",
                        style: .secondary
                    ) {
                        saveFeedback(action: .skip)
                        onComplete(workout)
                    }
                }
            }
            .disabled(isSaving)
            .padding(.horizontal)

            if isSaving {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            } else if let saveError {
                Text(saveError)
                    .font(.lbBody(13))
                    .foregroundStyle(LB.amber)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Adjust Confirmation Overlay

    private var adjustConfirmationOverlay: some View {
        ZStack {
            LB.bg.opacity(0.7).ignoresSafeArea()
            confirmationCard
        }
        .transition(.opacity)
    }

    private var confirmationCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(LB.green)
            Text("Got it")
                .font(.lbDisplay(18, .semibold))
                .foregroundStyle(LB.textPrimary)
            Text("We'll bring this up next time you review your plan.")
                .font(.lbBody(14))
                .foregroundStyle(LB.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LB.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(LB.line, lineWidth: 1)
        )
        .padding(40)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                showAdjustConfirmation = false
                onComplete(workout)
            }
        }
    }

    // MARK: - Save

    private func makeFeedback(action: MissedWorkoutAction, newDate: Date? = nil) -> WorkoutFeedback? {
        guard let reason = selectedReason else { return nil }
        return WorkoutFeedback(
            workoutId: workout.id,
            workoutName: workout.displayName,
            scheduledDate: workout.scheduledDate,
            reason: reason,
            action: action,
            reasonNote: trimmedNote(for: reason),
            newDate: newDate
        )
    }

    private func trimmedNote(for reason: MissedWorkoutReason) -> String? {
        guard reason == .other || reason.setbackKind != nil else { return nil }
        // "Other" has always sent its note, empty or not.
        if reason == .other { return reasonNote }
        let trimmed = reasonNote.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func notePrompt(for reason: MissedWorkoutReason) -> String {
        switch reason {
        case .sick: return "Symptoms (optional)"
        case .injured: return "What hurts? (optional)"
        default: return "What happened?"
        }
    }

    private func setbackExplanation(for kind: SetbackKind) -> String {
        let day = min(SetbackDay(workout.scheduledDate), .today)
        if setbackStore.setback(kind: kind, covering: day) != nil
            || setbackStore.active.contains(where: { $0.kind == kind }) {
            return "This goes with the \(kind.label.lowercased()) you already logged."
        }
        return "This also logs an \(kind.label.lowercased()) starting that day, so your coach knows. You can mark yourself recovered from the Training tab."
    }

    /// A run lost to sickness or injury opens (or extends) the setback
    /// itself, so it is on record beyond this one run.
    private func noteSetbackIfNeeded() {
        guard let reason = selectedReason, let kind = reason.setbackKind else { return }
        let note = trimmedNote(for: reason)
        let date = workout.scheduledDate
        let store = setbackStore
        Task { await store.noteSetback(kind: kind, on: date, note: note) }
    }

    /// Records a missed-run check-in locally and uploads it fire-and-forget;
    /// a failed upload is retried by the next refresh.
    private func saveFeedback(action: MissedWorkoutAction, newDate: Date? = nil) {
        guard let feedback = makeFeedback(action: action, newDate: newDate) else { return }
        modelContext.insert(feedback)
        scheduleManager.feedbackSync.syncFeedback(feedback.payload, feedbackId: feedback.id, modelContext: modelContext)
        noteSetbackIfNeeded()
    }

    /// Records a check-in the server has already accepted.
    private func insertSynced(_ feedback: WorkoutFeedback) {
        feedback.synced = true
        modelContext.insert(feedback)
    }

    /// Skips a run that isn't due yet. Unlike a missed-run check-in this
    /// waits for the server: until the server knows, the watch keeps the run.
    private func skipUpcoming() {
        guard let feedback = makeFeedback(action: .skip) else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await scheduleManager.skipUpcomingWorkout(feedback.payload)
            } catch {
                AppLog.scheduling.error("Failed to skip workout \(workout.id, privacy: .public): \(String(describing: error), privacy: .public)")
                saveError = Self.unsavedMessage
                return
            }
            insertSynced(feedback)
            noteSetbackIfNeeded()
            Task { await scheduleManager.refreshAfterPlanChange() }
            onComplete(workout)
        }
    }

    /// Moves the run, then skips whatever already sits on the new day when the
    /// athlete chose "Move & skip". A missed run moves the way it always has
    /// (locally first, uploaded fire-and-forget); an upcoming one waits for
    /// the server, like a skip.
    private func move(to newDate: Date, skipping others: [MissedWorkoutInfo]) {
        guard let feedback = makeFeedback(action: .move, newDate: newDate) else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            if workout.isUpcoming {
                do {
                    try await scheduleManager.moveUpcomingWorkout(feedback.payload, to: newDate)
                } catch {
                    AppLog.scheduling.error("Failed to move workout \(workout.id, privacy: .public): \(String(describing: error), privacy: .public)")
                    saveError = Self.unsavedMessage
                    return
                }
                insertSynced(feedback)
            } else {
                modelContext.insert(feedback)
                scheduleManager.feedbackSync.syncFeedback(feedback.payload, feedbackId: feedback.id, modelContext: modelContext)
                if !(await scheduleManager.rescheduleWorkout(id: workout.id, to: newDate)) {
                    AppLog.scheduling.error("Failed to reschedule workout \(workout.id, privacy: .public) to \(newDate, privacy: .public)")
                }
            }

            noteSetbackIfNeeded()
            let stillOn = await scheduleManager.skipToMakeRoom(others, for: workout, modelContext: modelContext)
            if workout.isUpcoming || !others.isEmpty {
                Task { await scheduleManager.refreshAfterPlanChange() }
            }
            if stillOn.isEmpty {
                onComplete(workout)
            } else {
                partialFailure = Self.partialMoveMessage(moved: workout, stillOn: stillOn)
            }
        }
    }

    // MARK: - Action Button Helper

    private enum ActionButtonStyle { case prominent, secondary }

    private func actionButton(
        title: String,
        subtitle: String,
        icon: String,
        style: ActionButtonStyle,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .frame(width: 32)
                    .foregroundStyle(style == .prominent ? LB.accent : LB.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.lbBody(15, .semibold))
                        .foregroundStyle(LB.textPrimary)
                    Text(subtitle)
                        .font(.lbBody(12))
                        .foregroundStyle(LB.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13))
                    .foregroundStyle(LB.textMuted)
            }
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: LB.rInner, style: .continuous)
                    .fill(style == .prominent ? LB.accentTint(0.10) : LB.optionOff)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LB.rInner, style: .continuous)
                    .strokeBorder(style == .prominent ? LB.accent.opacity(0.35) : LB.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reason Chip

private struct ReasonChip: View {
    let reason: MissedWorkoutReason
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(reason.emoji)
                    .font(.callout)
                Text(reason.label)
                    .font(.lbBody(14, .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(isSelected ? LB.accentTint() : LB.optionOff)
            )
            .foregroundStyle(isSelected ? LB.accent : LB.textBright)
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(isSelected ? LB.accent.opacity(0.45) : LB.line, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Flow Layout

/// A simple flow layout that wraps chips to the next line when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    private struct ArrangementResult {
        var positions: [CGPoint]
        var sizes: [CGSize]
        var size: CGSize
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangementResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var sizes: [CGSize] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            // An item wider than a whole line gets the line and wraps inside
            // it. Left at its own width it would make the layout, and with it
            // the screen it sits on, wider than what was offered.
            if size.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            }
            sizes.append(size)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return ArrangementResult(
            positions: positions,
            sizes: sizes,
            size: CGSize(width: totalWidth, height: currentY + lineHeight)
        )
    }
}

// MARK: - Previews

#Preview("Feedback Sheet") {
    let workout = MissedWorkoutInfo(
        id: UUID(),
        displayName: "Easy 6K",
        scheduledDate: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    )

    NavigationStack {
        MissedWorkoutFeedbackSheet(
            workout: workout,
            currentIndex: 1,
            totalCount: 1,
            scheduleManager: WorkoutScheduleManager(apiClient: WorkoutAPIClient()),
            onComplete: { _ in }
        )
    }
    .modelContainer(for: WorkoutFeedback.self, inMemory: true)
    .environment(SetbackStore(apiClient: WorkoutAPIClient()))
}
