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

    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    /// Position in `metadata.phases`, not the phase itself: a plan repeats
    /// phase names ("Recovery" after each race), so a name can't say which
    /// one was tapped.
    @State private var selectedPhaseIndex: Int?

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
                .padding(.bottom, LB.Space.lg)

            if totalCount > 0 {
                segmentedProgress
                    .padding(.bottom, LB.Space.lg)
            }

            currentPhaseRow

            if let phases = plan.metadata?.phases, !phases.isEmpty {
                phasePills(phases)
                    .padding(.top, LB.Space.md)
            }

            if let index = selectedPhaseIndex,
               let phases = plan.metadata?.phases, phases.indices.contains(index) {
                phaseDetail(phases[index])
            }
        }
        .padding(LB.Space.heroInset)
        .background(
            RoundedRectangle(cornerRadius: LB.Radius.card, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [LB.heroTop, LB.heroBottom],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(LBCornerTicks())
                .clipShape(RoundedRectangle(cornerRadius: LB.Radius.card, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: LB.Radius.card, style: .continuous)
                .strokeBorder(LB.textPrimary.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 17, x: 0, y: 16)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: LB.Space.xs) {
                Text(plan.name)
                    .font(.lbDisplay(.headline, .semibold))
                    .tracking(-0.4)
                    .foregroundStyle(LB.textPrimary)
                if let dateRange {
                    Text(dateRange)
                        .font(.lbMono(.caption))
                        .tracking(-0.3)
                        .foregroundStyle(LB.textTertiary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: LB.Space.xs) {
                // Strength cycles have no queue workouts — a "0/0" reads broken.
                if totalCount > 0 {
                    HStack(spacing: 0) {
                        Text("\(completedCount)").foregroundStyle(LB.accent)
                        Text("/\(totalCount)").foregroundStyle(LB.textMuted)
                    }
                    .font(.lbMono(.metric, .semibold))
                }
                if let currentWeek = plan.currentWeek, let totalWeeks = plan.totalWeeks {
                    Text("WEEK \(currentWeek + 1)/\(totalWeeks)")
                        .font(.lbMono(.caption))
                        .tracking(0.5)
                        .foregroundStyle(LB.textTertiary)
                }
            }
        }
    }

    // MARK: - Segmented vital progress

    /// One segment per run while they fit. Laid out inside the width on
    /// offer: as a plain row, the gaps alone gave the bar a minimum width,
    /// and a plan with enough runs made the card, and with it the whole
    /// Training screen, wider than the display. Past that point the bar is
    /// drawn in one piece.
    private var segmentedProgress: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 4
            let count = max(totalCount, 1)
            let segmentWidth = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)

            if segmentWidth >= 3 {
                HStack(spacing: spacing) {
                    ForEach(0..<totalCount, id: \.self) { i in
                        let isDone = i < completedCount
                        let isCurrent = i == completedCount && completedCount < totalCount
                        RoundedRectangle(cornerRadius: LB.Radius.bar, style: .continuous)
                            .fill(isDone ? LB.green : (isCurrent ? LB.accent : LB.trackEmpty))
                            .frame(width: segmentWidth)
                            .shadow(color: isCurrent ? LB.accent.opacity(0.6) : .clear, radius: 5)
                    }
                }
            } else {
                let done = geo.size.width * completionFraction
                let marker = min(max(geo.size.width / CGFloat(count), 6), geo.size.width - done)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: LB.Radius.bar, style: .continuous)
                        .fill(LB.trackEmpty)
                    RoundedRectangle(cornerRadius: LB.Radius.bar, style: .continuous)
                        .fill(LB.green)
                        .frame(width: done)
                    if completedCount < totalCount {
                        RoundedRectangle(cornerRadius: LB.Radius.bar, style: .continuous)
                            .fill(LB.accent)
                            .frame(width: marker)
                            .offset(x: done)
                            .shadow(color: LB.accent.opacity(0.6), radius: 5)
                    }
                }
            }
        }
        .frame(height: 8)
    }

    // MARK: - Current phase row

    @ViewBuilder
    private var currentPhaseRow: some View {
        if let phase = plan.currentPhase {
            HStack(spacing: LB.Space.sm) {
                Image(systemName: "figure.run")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(LB.accent)
                Text("Current phase")
                    .font(.lbBody(.secondary))
                    .tracking(0.3)
                    .foregroundStyle(LB.textTertiary)
                Text("· \(phase.name)")
                    .font(.lbBody(.secondary, .semibold))
                    .foregroundStyle(LB.textPrimary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Phase Pills

    @ViewBuilder
    private func phasePills(_ phases: [PlanPhase]) -> some View {
        let currentWeek = plan.currentWeek ?? -1

        FlowLayout(spacing: LB.Space.sm) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, phase in
                let isCurrent = phase.weeks.contains(currentWeek)
                let isSelected = selectedPhaseIndex == index
                let highlight = isCurrent || isSelected

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedPhaseIndex = isSelected ? nil : index
                    }
                } label: {
                    Text(phase.name)
                        .font(.lbBody(.secondary, highlight ? .semibold : .medium))
                        .foregroundStyle(highlight ? LB.accent : LB.textTertiary)
                        .padding(.horizontal, LB.Space.md)
                        .padding(.vertical, LB.Space.sm)
                        .background(
                            RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                                .fill(highlight ? LB.accentTint() : LB.surfaceTile)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
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
        VStack(alignment: .leading, spacing: LB.Space.sm) {
            Rectangle().fill(LB.line).frame(height: 1).padding(.vertical, LB.Space.xs)

            HStack {
                Text(phase.name)
                    .font(.lbBody(.body, .semibold))
                    .foregroundStyle(LB.textPrimary)
                Spacer()
                if phase.weeks.count == 1 {
                    Text("Week \(phase.weeks[0] + 1)")
                        .font(.lbMono(.caption))
                        .foregroundStyle(LB.textTertiary)
                } else if let first = phase.weeks.first, let last = phase.weeks.last {
                    Text("Weeks \(first + 1)–\(last + 1)")
                        .font(.lbMono(.caption))
                        .foregroundStyle(LB.textTertiary)
                }
            }

            if let volume = phase.volumeTargetKm {
                HStack(spacing: LB.Space.xs) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(LB.accent)
                    Text("Target: \(Int(units.distanceValue(km: volume).rounded())) \(units.distanceUnit)/week")
                        .font(.lbBody(.secondary))
                        .foregroundStyle(LB.textSecondary)
                }
            }

            if let notes = phase.notes {
                Text(notes)
                    .font(.lbBody(.secondary))
                    .foregroundStyle(LB.textSecondary)
            }

            let phaseWorkouts = workoutsInPhase(phase)
            if !phaseWorkouts.isEmpty {
                VStack(spacing: LB.Space.xs) {
                    ForEach(phaseWorkouts) { workout in
                        HStack(spacing: LB.Space.sm) {
                            Image(systemName: workout.status == "completed" ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(workout.status == "completed" ? LB.green : LB.textMuted)
                            Text(workout.title)
                                .font(.lbBody(.secondary))
                                .foregroundStyle(workout.status == "completed" ? LB.textPrimary : LB.textSecondary)
                            Spacer()
                        }
                    }
                }
                .padding(.top, LB.Space.xxs)
            }
        }
        .padding(.top, LB.Space.sm)
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
        HStack(spacing: LB.Space.md) {
            ProgressView()
                .controlSize(.small)
                .tint(LB.accent)
            Text("Loading training plan…")
                .font(.lbBody(.body))
                .foregroundStyle(LB.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(LB.Space.lg)
        .lbCard()
    }
}
