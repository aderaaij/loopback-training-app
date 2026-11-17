//
//  WorkoutHistoryView.swift
//  OpenHealthSync
//
//  Every workout in the history window (Settings → Sync), grouped by month,
//  with filters for activity and year. The Training tab's list shows only the
//  latest few and links here; with years of history, paging through that list
//  ten at a time never reaches the old ones.
//

import SwiftUI

struct WorkoutHistoryView: View {
    var workoutManager: WorkoutManager

    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    /// `WorkoutSummary.activityType` to show; nil = every activity.
    @State private var activity: String?
    /// Calendar year to show; nil = every year.
    @State private var year: Int?

    private struct ActivityOption: Identifiable {
        let key: String
        let name: String
        let count: Int
        var id: String { key }
    }

    private struct Month: Identifiable {
        let start: Date
        var workouts: [WorkoutSummary]
        var id: Date { start }
    }

    var body: some View {
        let all = workoutManager.allWorkouts.sorted { $0.startDate > $1.startDate }
        let inYear = all.filter { year == nil || Self.year(of: $0.startDate) == year }
        let shown = inYear.filter { activity == nil || $0.activityType == activity }
        let months = Self.months(from: shown)

        List {
            Section {
                activityChips(Self.activityOptions(from: inYear), total: inYear.count)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text(Self.totalsLine(for: shown, units: units))
                    .font(.lbMono(11))
                    .foregroundStyle(LB.textTertiary)
            }

            if shown.isEmpty {
                Section {
                    Text("No workouts match these filters.")
                        .font(.lbBody(14))
                        .foregroundStyle(LB.textSecondary)
                }
                .listRowBackground(LB.surface)
            }

            ForEach(months) { month in
                Section {
                    ForEach(month.workouts) { summary in
                        NavigationLink {
                            WorkoutDetailView(summary: summary, workoutManager: workoutManager)
                        } label: {
                            WorkoutRow(
                                summary: summary,
                                status: workoutManager.extractionStatuses[summary.id]
                            )
                        }
                    }
                } header: {
                    HStack {
                        LBSectionHeader(title: month.start.formatted(.dateTime.month(.wide).year()))
                        Text(Self.totalsLine(for: month.workouts, units: units))
                            .font(.lbMono(11))
                            .foregroundStyle(LB.textTertiary)
                            .fixedSize()
                    }
                }
                .listRowBackground(LB.surface)
            }
        }
        .lbList()
        .navigationTitle("All Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Year", selection: $year) {
                        Text("All years").tag(Int?.none)
                        ForEach(Self.years(in: all), id: \.self) { value in
                            Text(String(value)).tag(Int?.some(value))
                        }
                    }
                } label: {
                    // Text, not an icon: the chosen year has to be readable
                    // at a glance, since it changes what the list covers.
                    Text(year.map(String.init) ?? "All years")
                        .font(.lbBody(14, .semibold))
                }
            }
        }
        .onAppear {
            if workoutManager.allWorkouts.isEmpty { workoutManager.fetchAllRecentWorkouts() }
        }
    }

    // MARK: - Activity chips

    private func activityChips(_ options: [ActivityOption], total: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", count: total, isOn: activity == nil) { activity = nil }
                ForEach(options) { option in
                    chip(option.name, count: option.count, isOn: activity == option.key) {
                        activity = option.key
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, count: Int, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.lbBody(13, .semibold))
                Text(String(count))
                    .font(.lbMono(11))
                    .opacity(0.7)
            }
            .foregroundStyle(isOn ? LB.accent : LB.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(isOn ? LB.accentTint() : LB.surface)
            )
            .overlay(
                Capsule().strokeBorder(isOn ? LB.accent.opacity(0.5) : LB.line, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) workouts")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Derivations

    private static func year(of date: Date) -> Int {
        Calendar.current.component(.year, from: date)
    }

    private static func years(in workouts: [WorkoutSummary]) -> [Int] {
        Array(Set(workouts.map { year(of: $0.startDate) })).sorted(by: >)
    }

    /// The activities present, most frequent first.
    private static func activityOptions(from workouts: [WorkoutSummary]) -> [ActivityOption] {
        var counts: [String: (name: String, count: Int)] = [:]
        for workout in workouts {
            counts[workout.activityType, default: (workout.activityName, 0)].count += 1
        }
        return counts
            .map { ActivityOption(key: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }

    /// Groups workouts, already newest first, into calendar months.
    private static func months(from workouts: [WorkoutSummary]) -> [Month] {
        let calendar = Calendar.current
        var months: [Month] = []
        for workout in workouts {
            let parts = calendar.dateComponents([.year, .month], from: workout.startDate)
            let start = calendar.date(from: parts) ?? workout.startDate
            if months.last?.start == start {
                months[months.count - 1].workouts.append(workout)
            } else {
                months.append(Month(start: start, workouts: [workout]))
            }
        }
        return months
    }

    /// "12 workouts · 84 km"; the distance part only when something has one.
    private static func totalsLine(for workouts: [WorkoutSummary], units: DisplayUnits) -> String {
        let count = "\(workouts.count) workout\(workouts.count == 1 ? "" : "s")"
        let meters = workouts.compactMap(\.distance).reduce(0, +)
        guard meters > 0 else { return count }
        return "\(count) · \(Int(units.distanceValue(meters: meters).rounded())) \(units.distanceUnit)"
    }
}
