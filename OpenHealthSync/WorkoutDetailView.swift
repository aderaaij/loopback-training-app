//
//  WorkoutDetailView.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 14/03/2026.
//

import SwiftUI
import HealthKit

// MARK: - Workout List

struct WorkoutListView: View {
    @ObservedObject var workoutManager: WorkoutManager
    @State private var showResyncConfirmation = false
    @State private var isResyncing = false

    private let filterOptions: [(String, HKWorkoutActivityType?)] = [
        ("All", nil),
        ("Run", .running),
        ("Walk", .walking),
        ("Cycle", .cycling),
        ("Hike", .hiking),
        ("Swim", .swimming),
        ("Strength", .functionalStrengthTraining),
    ]

    var body: some View {
        List {
            if workoutManager.workouts.isEmpty {
                ContentUnavailableView(
                    "No Workouts",
                    systemImage: "figure.run",
                    description: Text("No \(filterLabel.lowercased()) workouts found.")
                )
            } else {
                ForEach(workoutManager.workouts) { summary in
                    NavigationLink {
                        WorkoutDetailView(
                            summary: summary,
                            workoutManager: workoutManager
                        )
                    } label: {
                        WorkoutRow(
                            summary: summary,
                            status: workoutManager.extractionStatuses[summary.id]
                        )
                    }
                }
            }
        }
        .lbList()
        .navigationTitle("Workouts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    Button {
                        showResyncConfirmation = true
                    } label: {
                        if isResyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Re-sync All", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(isResyncing || workoutManager.workouts.isEmpty)

                    Menu {
                        ForEach(filterOptions, id: \.0) { label, type in
                            Button {
                                workoutManager.activeFilter = type
                                workoutManager.fetchRecentWorkouts()
                            } label: {
                                if workoutManager.activeFilter == type {
                                    Label(label, systemImage: "checkmark")
                                } else {
                                    Text(label)
                                }
                            }
                        }
                    } label: {
                        Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .confirmationDialog(
            "Re-sync all \(filterLabel.lowercased()) workouts?",
            isPresented: $showResyncConfirmation,
            titleVisibility: .visible
        ) {
            Button("Re-sync All (\(workoutManager.workouts.count) workouts)") {
                isResyncing = true
                Task {
                    await workoutManager.resyncAll()
                    isResyncing = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will re-extract and re-send all workouts to the server.")
        }
        .onAppear {
            workoutManager.fetchRecentWorkouts()
        }
    }

    private var filterLabel: String {
        filterOptions.first(where: { $0.1 == workoutManager.activeFilter })?.0 ?? "All"
    }
}

// MARK: - Workout Row

struct WorkoutRow: View {
    let summary: WorkoutSummary
    var status: WorkoutExtractionStatus?

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(LB.accent)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LB.surfaceTile)
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(summary.activityName)
                    .font(.lbDisplay(15, .semibold))
                    .foregroundStyle(LB.textPrimary)

                HStack(spacing: 10) {
                    Text(summary.startDate, style: .date)
                    if let distance = summary.distance {
                        Text(formatDistance(distance))
                    }
                    Text(formatDuration(summary.duration))
                }
                .font(.lbMono(11))
                .foregroundStyle(LB.textTertiary)
            }

            Spacer()

            statusIndicator
        }
    }

    private var iconName: String {
        switch summary.activityType {
        case "running": return "figure.run"
        case "walking": return "figure.walk"
        case "cycling": return "figure.outdoor.cycle"
        case "hiking": return "figure.hiking"
        case "swimming": return "figure.pool.swim"
        case "yoga": return "figure.yoga"
        case "functionalStrength", "traditionalStrength": return "figure.strengthtraining.functional"
        case "coreTraining": return "figure.core.training"
        case "hiit": return "figure.highintensity.intervaltraining"
        case "cooldown": return "figure.cooldown"
        case "flexibility": return "figure.flexibility"
        case "pilates": return "figure.pilates"
        case "cardioDance", "socialDance": return "figure.dance"
        case "elliptical": return "figure.elliptical"
        case "rowing": return "figure.rower"
        case "crossTraining", "mixedCardio": return "figure.mixed.cardio"
        case "jumpRope": return "figure.jumprope"
        case "climbing": return "figure.climbing"
        case "boxing", "kickboxing": return "figure.boxing"
        case "tennis", "tableTennis", "badminton": return "figure.tennis"
        case "soccer": return "figure.soccer"
        case "basketball": return "figure.basketball"
        case "golf": return "figure.golf"
        case "snowboarding", "downhillSkiing", "snowSports": return "figure.snowboarding"
        case "crossCountrySkiing": return "figure.skiing.crosscountry"
        case "surfing": return "figure.surfing"
        case "mindAndBody": return "brain.head.profile"
        default: return "figure.mixed.cardio"
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .sent:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(LB.green)
                .font(.caption)
        case .extracting, .sending:
            ProgressView()
                .controlSize(.small)
                .tint(LB.accent)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(LB.red)
                .font(.caption)
        default:
            EmptyView()
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        let km = meters / 1000
        return String(format: "%.2f km", km)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h \(mins)m"
        }
        return "\(minutes):\(String(format: "%02d", secs))"
    }
}

// MARK: - Workout Detail

struct WorkoutDetailView: View {
    let summary: WorkoutSummary
    @ObservedObject var workoutManager: WorkoutManager

    @State private var detailed: DetailedWorkout?
    @State private var loading = true

    private var status: WorkoutExtractionStatus {
        workoutManager.extractionStatuses[summary.id] ?? .notExtracted
    }

    private let grid = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleHeader

                if loading {
                    loadingTile
                } else if let d = detailed {
                    richContent(d)
                } else {
                    summaryStatGrid
                }

                extractionCard
            }
            .padding(18)
        }
        .background(LB.bg)
        .navigationTitle(summary.activityName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            detailed = await workoutManager.getDetailedWorkout(for: summary.id)
            loading = false
        }
    }

    // MARK: Header

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.activityName)
                .font(.lbDisplay(24, .bold))
                .tracking(-0.6)
                .foregroundStyle(LB.textPrimary)
            Text(metaLine)
                .font(.lbMono(11))
                .foregroundStyle(LB.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingTile: some View {
        HStack(spacing: 10) {
            ProgressView().tint(LB.accent)
            Text("Loading workout data…")
                .font(.lbBody(14))
                .foregroundStyle(LB.textSecondary)
            Spacer()
        }
        .padding(20)
        .lbCard()
    }

    // MARK: Rich content (from DetailedWorkout)

    @ViewBuilder
    private func richContent(_ d: DetailedWorkout) -> some View {
        statSection(d)

        if let route = d.route, route.count > 1 {
            LBDetailSection(title: "Route", trailing: routeTrailing(d), fill: LB.surfaceSunken) {
                LBRouteMap(route: route)
            }
        }

        if let hr = d.heartRate, hr.count > 1 {
            LBDetailSection(title: "Heart rate", trailing: hrTrailing(hr), fill: LB.surfaceSunken) {
                LBHeartRateChart(series: hr)
            }
        }

        if let splits = d.splits, !splits.isEmpty {
            LBDetailSection(title: "1 km splits", trailing: splitsTrailing(splits)) {
                LBSplitsList(splits: splits)
            }
        }
    }

    // MARK: Stat grid + effort gauge (equal-height row)

    private struct StatSpec: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        var unit: String? = nil
        var accent: Bool = false
    }

    private func statSpecs(_ d: DetailedWorkout) -> [StatSpec] {
        var specs: [StatSpec] = []
        if let dist = d.totalDistance, dist > 0 {
            specs.append(StatSpec(label: "Distance", value: String(format: "%.2f", dist / 1000), unit: "km"))
        }
        specs.append(StatSpec(label: "Duration", value: formatDuration(d.duration)))
        if let dist = d.totalDistance, dist > 0 {
            specs.append(StatSpec(label: "Avg pace",
                                  value: paceValue(duration: d.duration, distance: dist),
                                  unit: "/km", accent: true))
        }
        if let hr = avgHR(d) {
            specs.append(StatSpec(label: "Avg HR", value: "\(hr)", unit: "bpm"))
        }
        return specs
    }

    @ViewBuilder
    private func statSection(_ d: DetailedWorkout) -> some View {
        let specs = statSpecs(d)
        if let effort = d.effortScore ?? d.estimatedEffortScore {
            // Stat rows stretch to match the (taller) gauge so the bottoms align.
            HStack(alignment: .top, spacing: 12) {
                statColumn(specs, stretch: true)
                LBEffortGauge(score: effort,
                              estimated: d.effortScore == nil,
                              zone: effortZone(d))
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            statColumn(specs, stretch: false)
        }
    }

    private func statColumn(_ specs: [StatSpec], stretch: Bool) -> some View {
        let rows = stride(from: 0, to: specs.count, by: 2).map {
            Array(specs[$0..<min($0 + 2, specs.count)])
        }
        return VStack(spacing: 12) {
            ForEach(rows.indices, id: \.self) { ri in
                HStack(spacing: 12) {
                    ForEach(rows[ri]) { spec in
                        LBStatTile(label: spec.label, value: spec.value,
                                   unit: spec.unit, accent: spec.accent, stretch: stretch)
                    }
                    if rows[ri].count == 1 {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: stretch ? .infinity : nil)
            }
        }
    }

    // MARK: Fallback (summary only)

    private var summaryStatGrid: some View {
        LazyVGrid(columns: grid, spacing: 12) {
            if let distance = summary.distance, distance > 0 {
                LBStatTile(label: "Distance", value: String(format: "%.2f", distance / 1000), unit: "km")
            }
            LBStatTile(label: "Duration", value: formatDuration(summary.duration))
            if let distance = summary.distance, distance > 0 {
                LBStatTile(label: "Avg pace",
                           value: paceValue(duration: summary.duration, distance: distance),
                           unit: "/km", accent: true)
            }
        }
    }

    // MARK: Derived strings

    private var metaLine: String {
        let kind = summary.activityName.uppercased()
        let date = summary.startDate.formatted(.dateTime.day().month(.abbreviated).year()).uppercased()
        let time = summary.startDate.formatted(.dateTime.hour().minute())
        return "\(kind) · \(date) · \(time)"
    }

    private func avgHR(_ d: DetailedWorkout) -> Int? {
        guard let hr = d.heartRate else { return nil }
        let vals = hr.map(\.value).filter { $0 > 0 }
        guard !vals.isEmpty else { return nil }
        return Int((vals.reduce(0, +) / Double(vals.count)).rounded())
    }

    /// Average heart-rate zone, estimated from avg HR vs an assumed max HR
    /// (we don't have the athlete's true max, so this is approximate).
    private func effortZone(_ d: DetailedWorkout) -> LBEffortZone? {
        guard let hr = d.heartRate else { return nil }
        let vals = hr.map(\.value).filter { $0 > 0 }
        guard !vals.isEmpty else { return nil }
        let avg = vals.reduce(0, +) / Double(vals.count)
        let maxHR = max(vals.max() ?? 0, 190)
        let pct = avg / maxHR
        let zone: Int
        switch pct {
        case ..<0.60: zone = 1
        case ..<0.70: zone = 2
        case ..<0.80: zone = 3
        case ..<0.90: zone = 4
        default:      zone = 5
        }
        let names   = ["", "Recovery", "Easy", "Moderate", "Threshold", "Max"]
        let colors  = [LB.zone1, LB.zone1, LB.zone2, LB.zone3, LB.zone4, LB.zone5]
        return LBEffortZone(
            type: zone <= 3 ? "Aerobic" : "Anaerobic",
            detail: "Zone \(zone) · \(names[zone])",
            color: colors[zone]
        )
    }

    private func routeTrailing(_ d: DetailedWorkout) -> String {
        guard let dist = d.totalDistance, dist > 0 else { return "GPS" }
        return String(format: "GPS · %.2f km", dist / 1000)
    }

    private func hrTrailing(_ hr: [TimeSeries]) -> String {
        let vals = hr.map(\.value).filter { $0 > 0 }
        guard !vals.isEmpty else { return "" }
        let avg = Int((vals.reduce(0, +) / Double(vals.count)).rounded())
        let mx = Int(vals.max() ?? 0)
        return "\(avg) avg · \(mx) max"
    }

    private func splitsTrailing(_ splits: [Split]) -> String {
        let paces = splits.map(\.pace).filter { $0 > 0 }
        guard !paces.isEmpty else { return "" }
        let avg = paces.reduce(0, +) / Double(paces.count)
        let m = Int(avg) / 60, s = Int(avg) % 60
        return "avg \(m):\(String(format: "%02d", s))"
    }

    private var extractionCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Extraction")
                    .font(.lbBody(14))
                    .foregroundStyle(LB.textBright)
                Spacer()
                extractionStatusRow
            }
            .padding(.vertical, 14)

            Rectangle().fill(LB.line).frame(height: 1)

            extractButton
                .padding(.vertical, 14)
        }
        .padding(.horizontal, 16)
        .lbCard()
    }

    @ViewBuilder
    private var extractionStatusRow: some View {
        switch status {
        case .notExtracted:
            Text("Not extracted")
                .font(.lbMono(12))
                .foregroundStyle(LB.textTertiary)
        case .extracting:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).tint(LB.accent)
                Text("Extracting…").font(.lbMono(12)).foregroundStyle(LB.textSecondary)
            }
        case .sending:
            HStack(spacing: 7) {
                ProgressView().controlSize(.small).tint(LB.accent)
                Text("Sending…").font(.lbMono(12)).foregroundStyle(LB.textSecondary)
            }
        case .sent(let date):
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LB.green)
                Text("Sent \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.lbMono(12))
                    .foregroundStyle(LB.textSecondary)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(LB.red)
                Text(message)
                    .font(.lbMono(11))
                    .foregroundStyle(LB.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var extractButton: some View {
        switch status {
        case .extracting, .sending:
            HStack {
                Text("Working…")
                    .font(.lbBody(14, .semibold))
                    .foregroundStyle(LB.textMuted)
                Spacer()
            }
        default:
            Button {
                Task { await workoutManager.extractAndSend(workoutID: summary.id) }
            } label: {
                HStack {
                    Text(isSent ? "Re-extract & send" : "Extract & send")
                        .font(.lbBody(14, .semibold))
                        .foregroundStyle(LB.accent)
                    Spacer()
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 16))
                        .foregroundStyle(LB.accent)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var isSent: Bool {
        if case .sent = status { return true }
        return false
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h \(mins)m \(secs)s"
        }
        return "\(minutes):\(String(format: "%02d", secs))"
    }

    private func paceValue(duration: TimeInterval, distance: Double) -> String {
        guard distance > 0 else { return "--" }
        let paceSecondsPerKm = duration / (distance / 1000)
        let minutes = Int(paceSecondsPerKm) / 60
        let seconds = Int(paceSecondsPerKm) % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
