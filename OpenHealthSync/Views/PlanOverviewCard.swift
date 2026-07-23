//
//  PlanOverviewCard.swift
//  OpenHealthSync
//
//  Created by Claude on 04/04/2026.
//  Reskinned to the Loopback "plan hero" design.
//

import SwiftUI
import WorkoutKit

struct PlanOverviewCard: View {
    let plan: TrainingPlan
    let planWorkouts: [PlanWorkout]
    let scheduledWorkouts: [ScheduledWorkoutPlan]

    @State private var selectedPhase: PlanPhase?

    private var completedCount: Int {
        let planWorkoutIds = Set(planWorkouts.map { $0.id })
        let scheduledCompleted = scheduledWorkouts
            .filter { $0.complete && planWorkoutIds.contains($0.plan.id) }.count
        let serverCompleted = planWorkouts.filter { $0.status == "completed" }.count
        return max(scheduledCompleted, serverCompleted)
    }

    private var totalCount: Int { planWorkouts.count }

    private var completionFraction: Double {
        guard totalCount > 0 else { return 0 }
        return Double(completedCount) / Double(totalCount)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var dateRange: String? {
        guard let start = plan.start, let end = plan.end else { return nil }
        return "\(Self.dateFormatter.string(from: start)) — \(Self.dateFormatter.string(from: end))".uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)

            if totalCount > 0 {
                segmentedProgress
                    .padding(.bottom, 16)
            }

            currentPhaseRow

            if let phases = plan.metadata?.phases, !phases.isEmpty {
                phasePills(phases)
                    .padding(.top, 12)
            }

            if let phase = selectedPhase {
                phaseDetail(phase)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: LB.rHero, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [LB.heroTop, LB.heroBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(LBCornerTicks())
                .clipShape(RoundedRectangle(cornerRadius: LB.rHero, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LB.rHero, style: .continuous)
                .strokeBorder(LB.textPrimary.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 17, x: 0, y: 16)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.name)
                    .font(.lbDisplay(23, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(LB.textPrimary)
                if let dateRange {
                    Text(dateRange)
                        .font(.lbMono(12))
                        .tracking(-0.3)
                        .foregroundStyle(LB.textTertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                // Strength cycles have no queue workouts — a "0/0" reads broken.
                if totalCount > 0 {
                    HStack(spacing: 0) {
                        Text("\(completedCount)").foregroundStyle(LB.accent)
                        Text("/\(totalCount)").foregroundStyle(LB.textMuted)
                    }
                    .font(.lbMono(26, .semibold))
                }
                if let currentWeek = plan.currentWeek, let totalWeeks = plan.totalWeeks {
                    Text("WEEK \(currentWeek + 1)/\(totalWeeks)")
                        .font(.lbMono(11))
                        .tracking(0.5)
                        .foregroundStyle(LB.textTertiary)
                }
            }
        }
    }

    // MARK: - Segmented vital progress

    private var segmentedProgress: some View {
        HStack(spacing: 4) {
            ForEach(0..<totalCount, id: \.self) { i in
                let isDone = i < completedCount
                let isCurrent = i == completedCount && completedCount < totalCount
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isDone ? LB.green : (isCurrent ? LB.accent : LB.trackEmpty))
                    .frame(maxWidth: .infinity)
                    .frame(height: 8)
                    .shadow(color: isCurrent ? LB.accent.opacity(0.6) : .clear, radius: 5)
            }
        }
    }

    // MARK: - Current phase row

    @ViewBuilder
    private var currentPhaseRow: some View {
        if let phase = plan.currentPhase {
            HStack(spacing: 8) {
                Image(systemName: "figure.run")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LB.accent)
                Text("Current phase")
                    .font(.lbBody(13))
                    .tracking(0.3)
                    .foregroundStyle(LB.textTertiary)
                Text("· \(phase.name)")
                    .font(.lbBody(13, .semibold))
                    .foregroundStyle(LB.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Phase Pills

    @ViewBuilder
    private func phasePills(_ phases: [PlanPhase]) -> some View {
        let currentWeek = plan.currentWeek ?? -1

        FlowLayout(spacing: 7) {
            ForEach(phases) { phase in
                let isCurrent = phase.weeks.contains(currentWeek)
                let isSelected = selectedPhase?.name == phase.name
                let highlight = isCurrent || isSelected

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedPhase = isSelected ? nil : phase
                    }
                } label: {
                    Text(phase.name)
                        .font(.lbBody(13, highlight ? .semibold : .medium))
                        .foregroundStyle(highlight ? LB.accent : LB.textTertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                                .fill(highlight ? LB.accentTint() : LB.surfaceTile)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                                .strokeBorder(highlight ? LB.accent.opacity(0.4) : .clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Phase Detail

    @ViewBuilder
    private func phaseDetail(_ phase: PlanPhase) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(LB.line).frame(height: 1).padding(.vertical, 4)

            HStack {
                Text(phase.name)
                    .font(.lbBody(14, .semibold))
                    .foregroundStyle(LB.textPrimary)
                Spacer()
                if phase.weeks.count == 1 {
                    Text("Week \(phase.weeks[0] + 1)")
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                } else if let first = phase.weeks.first, let last = phase.weeks.last {
                    Text("Weeks \(first + 1)–\(last + 1)")
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }

            if let volume = phase.volumeTargetKm {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LB.accent)
                    Text("Target: \(Int(volume)) km/week")
                        .font(.lbBody(13))
                        .foregroundStyle(LB.textSecondary)
                }
            }

            if let notes = phase.notes {
                Text(notes)
                    .font(.lbBody(13))
                    .foregroundStyle(LB.textSecondary)
            }

            let phaseWorkouts = workoutsInPhase(phase)
            if !phaseWorkouts.isEmpty {
                VStack(spacing: 4) {
                    ForEach(phaseWorkouts) { workout in
                        HStack(spacing: 7) {
                            Image(systemName: workout.status == "completed" ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(workout.status == "completed" ? LB.green : LB.textMuted)
                            Text(workout.title)
                                .font(.lbBody(13))
                                .foregroundStyle(workout.status == "completed" ? LB.textPrimary : LB.textSecondary)
                            Spacer()
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.top, 8)
    }

    /// Find plan workouts that fall within a phase's week range.
    private func workoutsInPhase(_ phase: PlanPhase) -> [PlanWorkout] {
        guard let startDate = plan.start else { return [] }
        let calendar = Calendar.current

        return planWorkouts.filter { workout in
            let date = workout.scheduledDate
                ?? scheduledWorkouts.first { $0.plan.id == workout.id }
                    .flatMap { calendar.date(from: $0.date) }
            guard let date else { return false }
            let days = calendar.dateComponents([.day], from: startDate, to: date).day ?? 0
            let week = max(0, days / 7)
            return phase.weeks.contains(week)
        }
    }
}

// MARK: - Loading Placeholder

struct PlanLoadingPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .tint(LB.accent)
            Text("Loading training plan…")
                .font(.lbBody(15))
                .foregroundStyle(LB.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .lbCard()
    }
}
