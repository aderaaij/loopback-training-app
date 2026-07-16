//
//  PlanCelebrationView.swift
//  OpenHealthSync
//
//  Plan wrap-up flow: a banner that appears when the server marks a plan
//  finishable, and the celebration sheet that confirms completion with an
//  optional 1–5 rating + free-text feedback. The feedback lands server-side
//  as a plan note the coach LLM reads when shaping the next block.
//

import SwiftUI
import UIKit

// MARK: - Banner

/// Compact call-to-action shown on the training tab while a plan is
/// finishable. Passive by design: it persists until the plan is actually
/// completed (from any surface), and tapping it opens the celebration sheet.
struct PlanCompletionBanner: View {
    let plan: TrainingPlan
    @ObservedObject var scheduleManager: WorkoutScheduleManager

    var body: some View {
        Button {
            scheduleManager.presentCelebration(for: plan)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 19))
                    .foregroundStyle(LB.accent)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LB.accentTint())
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(plan.name) is wrapped")
                        .font(.lbDisplay(15, .semibold))
                        .foregroundStyle(LB.textPrimary)
                        .lineLimit(1)
                    Text("Tap to celebrate and close it out")
                        .font(.lbBody(13))
                        .foregroundStyle(LB.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LB.textTertiary)
            }
            .padding(14)
            .lbCard(border: LB.accent.opacity(0.35))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Celebration Sheet

struct PlanCelebrationSheet: View {
    let plan: TrainingPlan
    @ObservedObject var scheduleManager: WorkoutScheduleManager

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case form
        case submitting
        case done(nextPlan: TrainingPlan?)
    }

    @State private var phase: Phase = .form
    @State private var rating = 0
    @State private var feedback = ""
    @State private var errorMessage: String?
    @State private var didComplete = false
    /// Another surface (dashboard / coach) completed the plan first — the
    /// only action left is closing the sheet.
    @State private var conflicted = false
    @State private var trophyShown = false

    /// All queued runs retired vs. the window lapsing with runs left over —
    /// the latter is framed as "wrap up", not a perfect score.
    private var isCleanFinish: Bool {
        guard let progress = plan.progress, progress.runsTotal > 0 else { return true }
        return progress.runsRemaining == 0
    }

    private var isSubmitting: Bool {
        if case .submitting = phase { return true }
        return false
    }

    var body: some View {
        ZStack {
            LB.bg.ignoresSafeArea()

            switch phase {
            case .form, .submitting:
                form
            case .done(let nextPlan):
                doneView(nextPlan: nextPlan)
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear {
            if !didComplete && !conflicted {
                scheduleManager.snoozeCelebration(for: plan.id)
            }
        }
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(spacing: 0) {
                trophy
                    .padding(.top, 36)
                    .padding(.bottom, 20)

                Text(isCleanFinish ? "Plan complete!" : "Time to wrap up")
                    .font(.lbDisplay(26, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(LB.textPrimary)

                Text(plan.name)
                    .font(.lbBody(15))
                    .foregroundStyle(LB.textSecondary)
                    .padding(.top, 4)

                statsRow
                    .padding(.top, 22)

                if !conflicted {
                    starRating
                        .padding(.top, 26)

                    feedbackField
                        .padding(.top, 18)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.lbBody(13))
                        .foregroundStyle(LB.amber)
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                }

                buttons
                    .padding(.top, 26)
                    .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                trophyShown = true
            }
        }
    }

    private var trophy: some View {
        Image(systemName: "trophy.fill")
            .font(.system(size: 44))
            .foregroundStyle(LB.accent)
            .frame(width: 96, height: 96)
            .background(Circle().fill(LB.accentTint()))
            .overlay(Circle().strokeBorder(LB.accent.opacity(0.35), lineWidth: 1))
            .shadow(color: LB.accent.opacity(0.5), radius: 24)
            .scaleEffect(trophyShown ? 1 : 0.4)
            .opacity(trophyShown ? 1 : 0)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            if let progress = plan.progress, progress.runsTotal > 0 {
                statBlock(value: "\(progress.runsCompleted)", label: "Sessions")
                if progress.runsSkipped > 0 {
                    statBlock(value: "\(progress.runsSkipped)", label: "Skipped")
                }
            }
            if let weeks = plan.totalWeeks {
                statBlock(value: "\(weeks)", label: weeks == 1 ? "Week" : "Weeks")
            }
        }
    }

    private func statBlock(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.lbMono(24, .semibold))
                .foregroundStyle(LB.textPrimary)
            Text(label.uppercased())
                .font(.lbBody(10, .semibold))
                .tracking(0.5)
                .foregroundStyle(LB.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .lbCard(fill: LB.surfaceAlt, radius: LB.rInner)
    }

    private var starRating: some View {
        VStack(spacing: 10) {
            Text("HOW WAS THIS BLOCK?")
                .font(.lbBody(11, .semibold))
                .tracking(0.6)
                .foregroundStyle(LB.textTertiary)

            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        // Tapping the current rating clears it — both fields
                        // are optional, a bare completion is valid.
                        rating = (rating == star) ? 0 : star
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 28))
                            .foregroundStyle(star <= rating ? LB.accent : LB.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var feedbackField: some View {
        TextField(
            "",
            text: $feedback,
            prompt: Text("What worked, what didn't? Your coach reads this when shaping the next block.")
                .font(.lbBody(14))
                .foregroundStyle(LB.textMuted),
            axis: .vertical
        )
        .font(.lbBody(14))
        .foregroundStyle(LB.textPrimary)
        .lineLimit(3...6)
        .padding(14)
        .lbCard(fill: LB.surfaceAlt, radius: LB.rInner)
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            if conflicted {
                Button {
                    dismiss()
                } label: {
                    Text("Close")
                        .font(.lbBody(16, .semibold))
                        .foregroundStyle(LB.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .lbCard(fill: LB.surfaceTile, radius: LB.rPill)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    submit()
                } label: {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(LB.bg)
                        } else {
                            Text("Complete Plan")
                                .font(.lbBody(16, .semibold))
                        }
                    }
                    .foregroundStyle(LB.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                            .fill(LB.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)

                Button {
                    dismiss()
                } label: {
                    Text("Not now")
                        .font(.lbBody(15, .medium))
                        .foregroundStyle(LB.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
        }
    }

    // MARK: Done

    private func doneView(nextPlan: TrainingPlan?) -> some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(LB.green)
                .shadow(color: LB.green.opacity(0.5), radius: 20)
                .padding(.bottom, 20)

            Text("That's a wrap")
                .font(.lbDisplay(26, .semibold))
                .tracking(-0.4)
                .foregroundStyle(LB.textPrimary)

            Text("\(plan.name) is in the books.")
                .font(.lbBody(15))
                .foregroundStyle(LB.textSecondary)
                .padding(.top, 4)

            Group {
                if let nextPlan {
                    nextUpCard(nextPlan)
                } else {
                    nudgeCard
                }
            }
            .padding(.top, 28)

            if rating > 0 || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Label("Your feedback is saved for the coach.", systemImage: "checkmark.circle")
                    .font(.lbBody(13))
                    .foregroundStyle(LB.textTertiary)
                    .padding(.top, 16)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.lbBody(16, .semibold))
                    .foregroundStyle(LB.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                            .fill(LB.accent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
    }

    private func nextUpCard(_ next: TrainingPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NEXT UP")
                .font(.lbBody(11, .semibold))
                .tracking(0.6)
                .foregroundStyle(LB.accent)
            Text(next.name)
                .font(.lbDisplay(17, .semibold))
                .foregroundStyle(LB.textPrimary)
            if let start = next.start {
                Text(start > Date()
                     ? "Starts \(PlanFormat.medium.string(from: start))"
                     : "Already underway")
                    .font(.lbMono(12))
                    .foregroundStyle(LB.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .lbCard(fill: LB.surfaceAlt, border: LB.accent.opacity(0.25))
    }

    private var nudgeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("What's next?", systemImage: "bubble.left.and.bubble.right")
                .font(.lbBody(14, .semibold))
                .foregroundStyle(LB.textPrimary)
            Text("No \(plan.activityType.lowercased()) plan lined up yet — start a conversation with your coach to shape the next block.")
                .font(.lbBody(14))
                .foregroundStyle(LB.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .lbCard(fill: LB.surfaceAlt)
    }

    // MARK: Submit

    private func submit() {
        phase = .submitting
        errorMessage = nil
        Task {
            let trimmed = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let next = try await scheduleManager.completePlan(
                    plan,
                    feedback: trimmed.isEmpty ? nil : trimmed,
                    rating: rating == 0 ? nil : rating
                )
                didComplete = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                    phase = .done(nextPlan: next)
                }
            } catch WorkoutAPIError.planNotActive {
                // Someone completed it via the dashboard or the coach first.
                // Refresh so the banner drops, and leave only "Close".
                conflicted = true
                errorMessage = WorkoutAPIError.planNotActive.errorDescription
                phase = .form
                await scheduleManager.loadActivePlan()
            } catch {
                errorMessage = error.localizedDescription
                phase = .form
            }
        }
    }
}
