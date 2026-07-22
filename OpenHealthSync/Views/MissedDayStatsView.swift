//
//  MissedDayStatsView.swift
//  OpenHealthSync
//
//  Statistics and history for missed workout days: which weekdays
//  get missed most, the reasons given at check-in, and the full
//  check-in history. Older misses that no longer belong to the
//  current plan live here instead of the Training list. Embedded as
//  the "Missed Days" segment of the Trends tab, which owns the
//  navigation chrome.
//

import SwiftUI
import SwiftData

struct MissedDayStatsView: View {
    var detector: MissedWorkoutDetector
    @Query(sort: \WorkoutFeedback.scheduledDate, order: .reverse)
    private var feedbackEntries: [WorkoutFeedback]

    @State private var checkInWorkout: MissedWorkoutInfo?

    // MARK: - Derived data

    /// Check-ins where the user actually picked a reason.
    private var checkedIn: [WorkoutFeedback] {
        feedbackEntries.filter { !$0.dismissed }
    }

    private var dismissedCount: Int {
        feedbackEntries.count - checkedIn.count
    }

    /// Every known missed date: recorded feedback plus pending
    /// (not-yet-checked-in) misses from the detector. The detector
    /// already excludes workouts that have feedback, so no overlap.
    private var allMissedDates: [Date] {
        feedbackEntries.map(\.scheduledDate) + detector.missedWorkouts.map(\.scheduledDate)
    }

    private var totalMissed: Int { allMissedDates.count }

    /// Counts indexed by `Calendar` weekday (1 = Sunday … 7 = Saturday).
    private var countsByWeekday: [Int: Int] {
        let calendar = Calendar.current
        return allMissedDates.reduce(into: [:]) { counts, date in
            counts[calendar.component(.weekday, from: date), default: 0] += 1
        }
    }

    /// Weekday indices in the user's calendar order (respects firstWeekday).
    private var orderedWeekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private var mostMissedWeekday: String? {
        guard let (weekday, count) = countsByWeekday.max(by: { $0.value < $1.value }),
              count > 0 else { return nil }
        return Calendar.current.weekdaySymbols[weekday - 1]
    }

    private var reasonCounts: [(reason: MissedWorkoutReason, count: Int)] {
        var counts: [MissedWorkoutReason: Int] = [:]
        for entry in checkedIn {
            counts[entry.reason, default: 0] += 1
        }
        var result: [(reason: MissedWorkoutReason, count: Int)] = []
        for reason in MissedWorkoutReason.allCases {
            if let count = counts[reason], count > 0 {
                result.append((reason: reason, count: count))
            }
        }
        return result.sorted { $0.count > $1.count }
    }

    private var actionCounts: [(action: MissedWorkoutAction, count: Int)] {
        var counts: [MissedWorkoutAction: Int] = [:]
        for entry in checkedIn {
            counts[entry.action, default: 0] += 1
        }
        var result: [(action: MissedWorkoutAction, count: Int)] = []
        for action in MissedWorkoutAction.allCases {
            if let count = counts[action], count > 0 {
                result.append((action: action, count: count))
            }
        }
        return result
    }

    var body: some View {
        Group {
            if totalMissed == 0 {
                ContentUnavailableView(
                    "No Missed Days",
                    systemImage: "checkmark.seal",
                    description: Text("When a scheduled workout goes by without being completed, it shows up here.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        summaryTiles
                        weekdayCard
                        if !reasonCounts.isEmpty || dismissedCount > 0 {
                            reasonsCard
                        }
                        if !detector.missedWorkouts.isEmpty {
                            needsCheckInCard
                        }
                        if !feedbackEntries.isEmpty {
                            historyCard
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
            }
        }
        .sheet(item: $checkInWorkout) { workout in
            MissedWorkoutFeedbackFlow(
                missedWorkouts: [workout],
                detector: detector
            )
        }
    }

    // MARK: - Summary tiles

    private var summaryTiles: some View {
        HStack(spacing: 10) {
            statTile(value: "\(totalMissed)", label: "Missed")
            statTile(value: mostMissedWeekday.map(shortWeekday) ?? "—", label: "Worst day")
            statTile(value: reasonCounts.first.map { $0.reason.emoji } ?? "—",
                     label: reasonCounts.first.map { shortReason($0.reason) } ?? "Top reason")
        }
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.lbMono(22, .semibold))
                .foregroundStyle(LB.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.lbBody(10, .semibold))
                .tracking(0.5)
                .foregroundStyle(LB.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .lbCard()
    }

    private func shortWeekday(_ name: String) -> String {
        String(name.prefix(3))
    }

    private func shortReason(_ reason: MissedWorkoutReason) -> String {
        switch reason {
        case .busy: return "Too busy"
        case .tired: return "Tired"
        case .weather: return "Weather"
        case .soreness: return "Sore"
        case .motivation: return "Not feeling it"
        case .other: return "Other"
        }
    }

    // MARK: - Weekday chart

    private var weekdayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            LBSectionHeader(title: "By day of week")
            weekdayBars
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbCard()
    }

    private var weekdayBars: some View {
        let maxCount = countsByWeekday.values.max() ?? 0
        let maxBarHeight: CGFloat = 88
        let symbols = Calendar.current.shortWeekdaySymbols

        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(orderedWeekdays, id: \.self) { weekday in
                let count = countsByWeekday[weekday] ?? 0
                VStack(spacing: 6) {
                    Text(count > 0 ? "\(count)" : " ")
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textSecondary)
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .fill(count > 0 ? LB.amber : LB.trackEmpty)
                        .frame(height: count > 0
                               ? max(6, maxBarHeight * CGFloat(count) / CGFloat(max(maxCount, 1)))
                               : 3)
                    Text(String(symbols[weekday - 1].prefix(2)).uppercased())
                        .font(.lbMono(10))
                        .foregroundStyle(LB.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Reasons

    private var reasonsCard: some View {
        let maxReasonCount = reasonCounts.map(\.count).max() ?? 1

        return VStack(alignment: .leading, spacing: 14) {
            LBSectionHeader(title: "Reasons given")

            ForEach(reasonCounts, id: \.reason) { entry in
                HStack(spacing: 10) {
                    Text(entry.reason.emoji)
                        .font(.system(size: 15))
                        .frame(width: 24)
                    Text(entry.reason.label)
                        .font(.lbBody(13, .medium))
                        .foregroundStyle(LB.textPrimary)
                        .frame(width: 110, alignment: .leading)
                        .lineLimit(1)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(LB.trackEmpty).frame(height: 5)
                            Capsule()
                                .fill(LB.amber)
                                .frame(width: max(5, geo.size.width * CGFloat(entry.count) / CGFloat(maxReasonCount)),
                                       height: 5)
                        }
                        .frame(maxHeight: .infinity)
                    }
                    Text("\(entry.count)")
                        .font(.lbMono(13))
                        .foregroundStyle(LB.textSecondary)
                        .frame(width: 24, alignment: .trailing)
                }
                .frame(height: 22)
            }

            if dismissedCount > 0 {
                Text("\(dismissedCount) dismissed without a reason")
                    .font(.lbBody(12))
                    .foregroundStyle(LB.textMuted)
            }

            if !actionCounts.isEmpty {
                Rectangle().fill(LB.line).frame(height: 1)
                HStack(spacing: 8) {
                    ForEach(actionCounts, id: \.action) { entry in
                        LBStatusChip(
                            text: "\(entry.count) \(entry.action.label)",
                            color: chipColor(for: entry.action)
                        )
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbCard()
    }

    private func chipColor(for action: MissedWorkoutAction) -> Color {
        switch action {
        case .move: return LB.blue
        case .adjust: return LB.amber
        case .skip: return LB.textSecondary
        }
    }

    // MARK: - Needs check-in

    private var needsCheckInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LBSectionHeader(title: "Needs check-in")

            ForEach(detector.missedWorkouts) { workout in
                Button {
                    checkInWorkout = workout
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(LB.amber)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(workout.displayName)
                                .font(.lbBody(13, .medium))
                                .foregroundStyle(LB.textPrimary)
                            Text(Self.dayFormatter.string(from: workout.scheduledDate))
                                .font(.lbMono(11))
                                .foregroundStyle(LB.textTertiary)
                        }
                        Spacer()
                        Text("Check in")
                            .font(.lbBody(12, .semibold))
                            .foregroundStyle(LB.amber)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(LB.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbCard()
    }

    // MARK: - History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LBSectionHeader(title: "History")

            ForEach(feedbackEntries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(Self.dayFormatter.string(from: entry.scheduledDate))
                            .font(.lbMono(11))
                            .foregroundStyle(LB.textTertiary)
                            .frame(width: 78, alignment: .leading)
                        Text(entry.workoutName)
                            .font(.lbBody(13, .medium))
                            .foregroundStyle(LB.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        if entry.dismissed {
                            LBStatusChip(text: "Dismissed", color: LB.textMuted)
                        } else {
                            LBStatusChip(text: entry.action.label, color: chipColor(for: entry.action))
                        }
                    }
                    if !entry.dismissed {
                        HStack(spacing: 5) {
                            Text("\(entry.reason.emoji) \(entry.reason.label)")
                                .font(.lbBody(12))
                                .foregroundStyle(LB.textSecondary)
                            if let note = entry.reasonNote, !note.isEmpty {
                                Text("— \(note)")
                                    .font(.lbBody(12))
                                    .foregroundStyle(LB.textTertiary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.leading, 86)
                    }
                }
                if entry.id != feedbackEntries.last?.id {
                    Rectangle().fill(LB.lineSoft).frame(height: 1)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbCard()
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()
}
