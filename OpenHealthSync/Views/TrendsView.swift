//
//  TrendsView.swift
//  OpenHealthSync
//
//  Long-range training trends from the server's workout aggregates
//  (GET /api/workouts/summary). The phone's HealthKit queries only cover the
//  last 6 months; the server keeps every synced workout, so this is the first
//  server-only screen — no local fallback, plain retry on failure, no cache.
//

import SwiftUI

struct TrendsView: View {
    let apiClient: WorkoutAPIClient
    var missedWorkoutDetector: MissedWorkoutDetector

    private enum LoadState {
        case loading, loaded, failed
    }

    private enum Segment {
        case mileage, missed
    }

    @State private var rows: [ServerWorkoutSummaryRow] = []
    @State private var loadState: LoadState = .loading
    @State private var segment: Segment = .mileage

    var body: some View {
        Group {
            switch segment {
            case .mileage:
                mileageContent
            case .missed:
                MissedDayStatsView(detector: missedWorkoutDetector)
            }
        }
        .lbScreen()
        .navigationTitle("Trends")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $segment) {
                    Text("Mileage").tag(Segment.mileage)
                    Text("Missed Days").tag(Segment.missed)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
        }
        .task { await load() }
    }

    private var mileageContent: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .tint(LB.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                errorCard
            case .loaded:
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No Trends Yet",
                        systemImage: "chart.line.uptrend.xyaxis",
                        description: Text("Once your runs sync to the server, long-range mileage trends show up here.")
                    )
                } else {
                    content
                }
            }
        }
    }

    private func load() async {
        loadState = .loading
        do {
            rows = try await apiClient.fetchWorkoutSummary(period: "month", activityType: "running")
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    // MARK: - Derived data

    /// Total distance (m), run count, and duration (s) for a calendar year.
    private func totals(forYear year: Int) -> (distance: Double, runs: Int, duration: Double) {
        let calendar = Calendar.current
        return rows.reduce(into: (0.0, 0, 0.0)) { acc, row in
            guard let start = row.periodStart,
                  calendar.component(.year, from: start) == year else { return }
            acc.0 += row.totalDistance ?? 0
            acc.1 += row.count
            acc.2 += row.totalDuration ?? 0
        }
    }

    /// Distance per month for the last 12 months, oldest first. Months with
    /// no synced runs are absent from the response, so gaps are filled with
    /// zero here.
    private var monthlyDistances: [(month: Date, km: Double)] {
        let calendar = Calendar.current
        let kmByMonth: [Date: Double] = rows.reduce(into: [:]) { acc, row in
            guard let start = row.periodStart else { return }
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
            acc[month, default: 0] += (row.totalDistance ?? 0) / 1000
        }
        guard let currentMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: Date())
        ) else { return [] }
        return (0..<12).reversed().compactMap { offset in
            guard let month = calendar.date(byAdding: .month, value: -offset, to: currentMonth) else {
                return nil
            }
            return (month, kmByMonth[month] ?? 0)
        }
    }

    // MARK: - Content

    private var content: some View {
        let thisYear = Calendar.current.component(.year, from: Date())
        let current = totals(forYear: thisYear)
        let previous = totals(forYear: thisYear - 1)

        return ScrollView {
            VStack(spacing: 14) {
                yearTiles(title: "\(thisYear)", totals: current)
                if previous.runs > 0 {
                    yearTiles(title: "\(thisYear - 1)", totals: previous)
                }
                monthlyCard
                Text("Trends cover synced workouts only — runs from before the app existed were never uploaded.")
                    .font(.lbBody(12))
                    .foregroundStyle(LB.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Year tiles

    private func yearTiles(title: String, totals: (distance: Double, runs: Int, duration: Double)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            LBSectionHeader(title: title)
            HStack(spacing: 10) {
                statTile(value: formatKm(totals.distance / 1000), label: "km")
                statTile(value: "\(totals.runs)", label: "Runs")
                statTile(value: formatHours(totals.duration), label: "Time")
            }
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

    // MARK: - Monthly bars

    private var monthlyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            LBSectionHeader(title: "Monthly distance")
            monthlyBars
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbCard()
    }

    private var monthlyBars: some View {
        let months = monthlyDistances
        let maxKm = months.map(\.km).max() ?? 0
        let maxBarHeight: CGFloat = 96

        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(months, id: \.month) { entry in
                VStack(spacing: 6) {
                    Text(entry.km > 0 ? "\(Int(entry.km.rounded()))" : " ")
                        .font(.lbMono(9))
                        .foregroundStyle(LB.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                        .fill(entry.km > 0 ? LB.accent : LB.trackEmpty)
                        .frame(height: entry.km > 0
                               ? max(6, maxBarHeight * CGFloat(entry.km) / CGFloat(max(maxKm, 1)))
                               : 3)
                    Text(Self.monthFormatter.string(from: entry.month).uppercased())
                        .font(.lbMono(9))
                        .foregroundStyle(LB.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Error state

    private var errorCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(LB.textTertiary)
            Text("Couldn't load trends")
                .font(.lbDisplay(16, .semibold))
                .foregroundStyle(LB.textPrimary)
            Text("Check your connection to the training server and try again.")
                .font(.lbBody(13))
                .foregroundStyle(LB.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await load() }
            } label: {
                Text("Retry")
                    .font(.lbBody(14, .semibold))
                    .foregroundStyle(LB.accent)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                            .fill(LB.accentTint())
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .lbCard()
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Formatting

    private func formatKm(_ km: Double) -> String {
        km >= 100 ? String(format: "%.0f", km) : String(format: "%.1f", km)
    }

    private func formatHours(_ seconds: Double) -> String {
        let hours = Int((seconds / 3600).rounded())
        return "\(hours)h"
    }

    /// Single-letter month labels under the bars ("J F M A …").
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMMM"
        return f
    }()
}
