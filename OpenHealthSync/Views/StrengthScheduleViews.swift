//
//  StrengthScheduleViews.swift
//  OpenHealthSync
//
//  Display-only UI for strength sessions and the active strength cycle.
//  Strength entries name a Hevy routine per day; they are never enqueued
//  to WorkoutKit / the watch.
//

import SwiftUI

// MARK: - Strength Session Row

/// A single strength session on the agenda: routine title, plan name,
/// completion ✓ and a subtle run-overlap warning.
struct StrengthSessionRow: View {
    let entry: CalendarEntry
    /// List contexts show the session's date; the day timeline doesn't need it.
    var showsDate: Bool = false

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private var subtitle: String {
        var parts: [String] = []
        if showsDate, let day = entry.day {
            parts.append(Self.dateFormatter.string(from: day))
        }
        if let planName = entry.planName {
            parts.append(planName)
        }
        return parts.isEmpty ? "Strength" : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "dumbbell.fill")
                .font(.system(size: 17))
                .foregroundStyle(LB.violet)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LB.surfaceTile)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.lbDisplay(15, .semibold))
                    .foregroundStyle(LB.textPrimary)
                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                    if entry.conflict {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Run day")
                                .font(.lbBody(11, .medium))
                        }
                        .foregroundStyle(LB.amber)
                    }
                }
            }

            Spacer()

            if entry.completed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(LB.green)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Strength Cycle Card

/// Compact card for the active strength cycle: name, weekly cadence and the
/// cycle horizon ("N days left" / "plan the next one" cue).
struct StrengthCycleCard: View {
    let plan: TrainingPlan
    var scheduleManager: WorkoutScheduleManager

    var body: some View {
        NavigationLink {
            PlanDetailView(plan: plan, scheduleManager: scheduleManager)
        } label: {
            StrengthCycleCardLabel(plan: plan)
        }
        .buttonStyle(.plain)
    }
}

/// The card's visual content, separate from navigation so List rows can pair
/// it with a hidden NavigationLink — a visible link as row content would get
/// the List's own chevron and link styling on top of the card's.
struct StrengthCycleCardLabel: View {
    let plan: TrainingPlan

    var body: some View {
        HStack(spacing: 13) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(LB.violet)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LB.surfaceTile)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.name)
                        .font(.lbDisplay(16, .semibold))
                        .foregroundStyle(LB.textPrimary)
                        .lineLimit(1)
                    if let cadence = plan.metadata?.schedule?.summary, !cadence.isEmpty {
                        Text(cadence)
                            .font(.lbBody(12))
                            .foregroundStyle(LB.textTertiary)
                            .lineLimit(1)
                    } else if let description = plan.description, !description.isEmpty {
                        Text(description)
                            .font(.lbBody(12))
                            .foregroundStyle(LB.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 5) {
                    horizonChip
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LB.textMuted)
                }
        }
        .padding(14)
        .lbCard()
    }

    /// The cycle-horizon cue: how long until the cycle ends, or the nudge to
    /// go back to Claude and build the next one.
    @ViewBuilder
    private var horizonChip: some View {
        if let days = plan.daysRemaining {
            if days < 0 {
                LBStatusChip(text: "Plan next cycle", color: LB.accent)
            } else if days == 0 {
                LBStatusChip(text: "Ends today", color: LB.amber)
            } else if days <= 7 {
                LBStatusChip(text: "\(days) day\(days == 1 ? "" : "s") left", color: LB.amber)
            } else {
                LBStatusChip(text: "\(days) days left", color: LB.textSecondary)
            }
        }
    }
}
