//
//  NutritionTrendsView.swift
//  OpenHealthSync
//
//  Read-only view of what the athlete has been eating, from the server's
//  daily nutrition rows (GET /api/nutrition). Embedded as the "Fuel" segment
//  of the Trends tab, which owns the navigation chrome.
//
//  Read-only on purpose: food logging happens in the athlete's food app,
//  which writes to Apple Health; Loopback reads from there and must not become
//  a second place to enter it. There is deliberately no energy-balance number —
//  intake and training energy stay separate (a "net" needs a BMR the app
//  doesn't have, and self-reported intake runs 10–30% low).
//

import SwiftUI

struct NutritionTrendsView: View {
    let apiClient: WorkoutAPIClient
    let healthMetricsSyncer: HealthMetricsSyncer

    /// How much history the screen pulls. Four weeks covers the coverage
    /// figure and the two-week chart with room for retroactive edits.
    private static let windowDays = 28
    /// The averaging and coverage window, in days ending today.
    private static let recentDays = 7
    /// Bars in the daily-energy chart.
    private static let chartDays = 14

    private enum LoadState {
        case loading, loaded, failed
    }

    @State private var days: [DailyNutrition] = []
    @State private var bodyMassKg: Double?
    @State private var loadState: LoadState = .loading
    @State private var isSyncing = false

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .tint(LB.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                errorCard
            case .loaded:
                if loggedDays.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loadState = .loading
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let start = calendar.date(byAdding: .day, value: -(Self.windowDays - 1), to: today) else {
            loadState = .failed
            return
        }

        do {
            days = try await apiClient.fetchNutrition(
                startDate: Self.wireFormatter.string(from: start),
                endDate: Self.wireFormatter.string(from: today)
            )
            // Local read — the protein-per-kg figure needs body mass, and the
            // app already holds that authorization.
            bodyMassKg = await healthMetricsSyncer.latestBodyMassKg()
            loadState = .loaded
        } catch {
            loadState = .failed
        }
    }

    /// Re-requests HealthKit authorization (idempotent for types already
    /// decided, and the only way newly-added dietary types get granted) and
    /// runs a sync, then reloads. Backs the empty state's one action.
    private func syncNow() async {
        isSyncing = true
        _ = await healthMetricsSyncer.requestAuthorization()
        try? await healthMetricsSyncer.syncMetrics()
        isSyncing = false
        await load()
    }

    // MARK: - Derived data

    /// Rows keyed by local day. The server only stores days that had something
    /// logged, so a missing key means "not tracked" — never zero.
    private var byDay: [Date: DailyNutrition] {
        let calendar = Calendar.current
        return days.reduce(into: [:]) { acc, row in
            guard let day = row.day else { return }
            acc[calendar.startOfDay(for: day)] = row
        }
    }

    /// Days in the fetched window that carry an intake figure.
    private var loggedDays: [DailyNutrition] {
        days.filter { $0.energyKcal != nil }
    }

    /// The last `recentDays` days, oldest first.
    private var recentDates: [Date] {
        Self.dates(back: Self.recentDays)
    }

    /// Rows inside the recent window that are safe to average: partial days are
    /// excluded exactly as the server excludes them — today's total is real but
    /// unfinished, and folding it in would drag every average down.
    private var averagedRows: [DailyNutrition] {
        let window = Set(recentDates)
        return days.filter { row in
            guard let day = row.day else { return false }
            return window.contains(Calendar.current.startOfDay(for: day))
                && !row.isPartial
                && row.energyKcal != nil
        }
    }

    /// Days in the recent window with anything logged, partial included —
    /// coverage is about logging adherence, so today counts.
    private var recentLoggedCount: Int {
        let rows = byDay
        return recentDates.filter { rows[$0]?.energyKcal != nil }.count
    }

    private func average(_ field: (DailyNutrition) -> Double?) -> Double? {
        let values = averagedRows.compactMap(field)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var avgEnergy: Double? { average(\.energyKcal) }
    private var avgCarbs: Double? { average(\.carbsG) }
    private var avgProtein: Double? { average(\.proteinG) }
    private var avgFat: Double? { average(\.fatG) }
    private var avgFiber: Double? { average(\.fiberG) }

    private var proteinPerKg: Double? {
        guard let avgProtein, let bodyMassKg, bodyMassKg > 0 else { return nil }
        return avgProtein / bodyMassKg
    }

    /// Every app that wrote a dietary entry in the window. Worth showing: it
    /// names the writer when two food apps disagree.
    private var sources: [String] {
        Set(days.flatMap { $0.sources ?? [] }).sorted()
    }

    private var avgEntriesPerLoggedDay: Double? {
        let counts = loggedDays.compactMap(\.entryCount)
        guard !counts.isEmpty else { return nil }
        return Double(counts.reduce(0, +)) / Double(counts.count)
    }

    private static func dates(back count: Int) -> [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<count).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                averagesTiles
                macroCard
                energyCard
                loggingCard
                Text("Intake comes from whichever app writes food to Apple Health, and self-reported logging typically runs low. Today is excluded from averages until the day is complete.")
                    .font(.lbBody(12))
                    .foregroundStyle(LB.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Averages

    private var averagesTiles: some View {
        VStack(alignment: .leading, spacing: 10) {
            LBSectionHeader(title: "Last \(Self.recentDays) days")
            HStack(spacing: 10) {
                LBTrendTile(value: avgEnergy.map { formatInt($0) } ?? "—", label: "kcal/day")
                LBTrendTile(value: avgProtein.map { formatInt($0) } ?? "—", label: "g protein")
                LBTrendTile(
                    value: proteinPerKg.map { String(format: "%.1f", $0) } ?? "—",
                    label: "g/kg"
                )
            }
            if proteinPerKg == nil, avgProtein != nil {
                Text("Protein per kilo needs a recent weight in Apple Health.")
                    .font(.lbBody(12))
                    .foregroundStyle(LB.textMuted)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Macro split

    private var macroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            LBSectionHeader(title: "Macros per day")
            if let carbs = avgCarbs, let protein = avgProtein, let fat = avgFat {
                // Shares are computed from grams via 4/4/9 kcal, not from
                // energy_kcal — that column also carries alcohol and rounding
                // from the logging app, so the two don't reconcile exactly.
                let kcal = [carbs * 4, protein * 4, fat * 9]
                let total = kcal.reduce(0, +)
                macroBar(shares: total > 0 ? kcal.map { $0 / total } : [0, 0, 0])
                VStack(spacing: 8) {
                    macroRow(label: "Carbs", grams: carbs, share: total > 0 ? kcal[0] / total : nil, color: LB.amber)
                    macroRow(label: "Protein", grams: protein, share: total > 0 ? kcal[1] / total : nil, color: LB.blue)
                    macroRow(label: "Fat", grams: fat, share: total > 0 ? kcal[2] / total : nil, color: LB.violet)
                    if let avgFiber {
                        macroRow(label: "Fiber", grams: avgFiber, share: nil, color: LB.green)
                    }
                }
            } else {
                Text("No macro breakdown in the last \(Self.recentDays) complete days.")
                    .font(.lbBody(13))
                    .foregroundStyle(LB.textSecondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbCard()
    }

    private func macroBar(shares: [Double]) -> some View {
        let colors = [LB.amber, LB.blue, LB.violet]
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(shares.enumerated()), id: \.offset) { index, share in
                    Capsule(style: .continuous)
                        .fill(colors[index])
                        .frame(width: max(0, geo.size.width * share - 2))
                }
            }
        }
        .frame(height: 10)
    }

    private func macroRow(label: String, grams: Double, share: Double?, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.lbBody(13))
                .foregroundStyle(LB.textSecondary)
            Spacer()
            if let share {
                Text("\(Int((share * 100).rounded()))%")
                    .font(.lbMono(12))
                    .foregroundStyle(LB.textTertiary)
            }
            Text("\(formatInt(grams)) g")
                .font(.lbMono(13, .semibold))
                .foregroundStyle(LB.textPrimary)
                .frame(minWidth: 58, alignment: .trailing)
        }
    }

    // MARK: - Daily energy chart

    private var energyCard: some View {
        let rows = byDay
        let series = Self.dates(back: Self.chartDays).map { date in
            (date: date, row: rows[date])
        }
        let values = series.compactMap { $0.row?.energyKcal }
        let maxKcal = values.max() ?? 0

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                LBSectionHeader(title: "Daily energy")
                Text("\(Self.chartDays) days")
                    .font(.lbMono(11))
                    .foregroundStyle(LB.textMuted)
            }
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(series, id: \.date) { entry in
                    energyBar(date: entry.date, row: entry.row, maxKcal: maxKcal)
                }
            }
            if let peak = values.max() {
                Text("Peak \(formatInt(peak)) kcal. Gaps are days with nothing logged — not days with nothing eaten.")
                    .font(.lbBody(12))
                    .foregroundStyle(LB.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lbCard()
    }

    private func energyBar(date: Date, row: DailyNutrition?, maxKcal: Double) -> some View {
        let maxBarHeight: CGFloat = 96
        let kcal = row?.energyKcal
        // A partial day is drawn dimmed rather than hidden: the value is real,
        // it just isn't final.
        let fill: Color = kcal == nil
            ? LB.trackEmpty
            : (row?.isPartial == true ? LB.accentTint(0.45) : LB.accent)

        return VStack(spacing: 6) {
            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                .fill(fill)
                .frame(height: kcal.map { value in
                    max(6, maxBarHeight * CGFloat(value) / CGFloat(max(maxKcal, 1)))
                } ?? 3)
            Text(Self.weekdayFormatter.string(from: date).uppercased())
                .font(.lbMono(9))
                .foregroundStyle(LB.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Logging adherence

    private var loggingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LBSectionHeader(title: "Logging")
            HStack(spacing: 10) {
                LBTrendTile(
                    value: "\(recentLoggedCount)/\(Self.recentDays)",
                    label: "Days logged",
                    valueColor: recentLoggedCount == Self.recentDays ? LB.green : LB.textPrimary
                )
                LBTrendTile(value: "\(loggedDays.count)/\(Self.windowDays)", label: "Last 4 wks")
                LBTrendTile(
                    value: avgEntriesPerLoggedDay.map { String(format: "%.1f", $0) } ?? "—",
                    label: "Entries/day"
                )
            }
            if !sources.isEmpty {
                Text("Logged in \(sources.joined(separator: ", ")).")
                    .font(.lbBody(12))
                    .foregroundStyle(LB.textMuted)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - Empty & error states
    //
    // An empty result must never be phrased as a fact about the athlete's
    // eating: HealthKit returns nothing at all for a *denied* dietary read, so
    // "no data" and "permission not granted" look identical from here.

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No intake synced yet", systemImage: "fork.knife")
        } description: {
            Text("Loopback reads food from Apple Health — log meals in your usual app. If you already do, check that Health is sharing Nutrition with Loopback: a denied permission looks exactly like an empty diary from here.")
        } actions: {
            Button {
                Task { await syncNow() }
            } label: {
                HStack(spacing: 8) {
                    if isSyncing {
                        ProgressView().tint(LB.accent)
                    }
                    Text(isSyncing ? "Syncing…" : "Check access & sync")
                        .font(.lbBody(14, .semibold))
                        .foregroundStyle(LB.accent)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                        .fill(LB.accentTint())
                )
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)
        }
    }

    private var errorCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(LB.textTertiary)
            Text("Couldn't load intake")
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

    private func formatInt(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// "yyyy-MM-dd" for the query bounds, fixed-locale so a non-Gregorian
    /// device calendar can't reshape the string the server parses.
    private static let wireFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Single-letter weekday labels under the bars.
    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEEE"
        return formatter
    }()
}
