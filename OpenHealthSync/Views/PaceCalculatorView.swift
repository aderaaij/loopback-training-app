//
//  PaceCalculatorView.swift
//  OpenHealthSync
//
//  Distance, time and pace for planning a race: fill in two, read the third,
//  and see the clock at every kilometer or mile on the way. Works offline and
//  touches nothing on the server; the arithmetic is in `PaceCalculator`.
//

import SwiftUI

struct PaceCalculatorView: View {
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault

    @State private var unknown: PaceCalculator.Unknown = .pace
    /// The preset behind the distance field, kept so a half marathon is
    /// 21 097.5 m rather than whatever "21.1" reads back as.
    @State private var race: RaceDistance?
    @State private var distanceText = ""
    @State private var hoursText = ""
    @State private var minutesText = ""
    @State private var secondsText = ""
    @State private var paceMinutesText = ""
    @State private var paceSecondsText = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case distance, hours, minutes, seconds, paceMinutes, paceSeconds
    }

    var body: some View {
        Form {
            Section {
                Picker("Work out", selection: $unknown) {
                    ForEach(PaceCalculator.Unknown.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Work out")
            }

            Section("Distance") {
                if unknown == .distance {
                    answerRow(result.map { units.distanceNumber(meters: $0.meters) }, unit: units.distanceUnit)
                } else {
                    raceChips
                    HStack {
                        Text("Distance")
                        Spacer()
                        TextField("0", text: $distanceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                            .focused($focus, equals: .distance)
                        Text(units.distanceUnit)
                            .foregroundStyle(LB.textTertiary)
                    }
                }
            }

            Section("Time") {
                if unknown == .time {
                    answerRow(result.map { PaceCalculator.clock($0.seconds) }, unit: nil)
                } else {
                    HStack(spacing: 12) {
                        Text("Time")
                        Spacer()
                        part($hoursText, "h", .hours)
                        part($minutesText, "min", .minutes)
                        part($secondsText, "s", .seconds)
                    }
                }
            }

            Section("Pace") {
                if unknown == .pace {
                    answerRow(
                        result.map { PaceCalculator.clock($0.secondsPerKm * unitMeters / 1000) },
                        unit: units.paceUnit
                    )
                } else {
                    HStack(spacing: 12) {
                        Text("Pace")
                        Spacer()
                        part($paceMinutesText, "min", .paceMinutes)
                        part($paceSecondsText, "s", .paceSeconds)
                        Text(units.paceUnit)
                            .foregroundStyle(LB.textTertiary)
                    }
                }
            }

            if let result {
                Section {
                    ForEach(PaceCalculator.splits(for: result, unitMeters: unitMeters)) { split in
                        splitRow(split)
                    }
                } header: {
                    Text("Splits")
                } footer: {
                    Text("The time on the clock at each mark, at an even pace from start to finish.")
                }
            }
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle("Pace Calculator")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // The number pads have no return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .onChange(of: distanceText) { _, text in
            // Typing over a preset's number lets go of the preset.
            if let race, text != presetText(race) { self.race = nil }
        }
        .onChange(of: unknown) { old, _ in
            carryOver(from: old)
        }
    }

    // MARK: - Rows

    private var raceChips: some View {
        HStack(spacing: 8) {
            ForEach(RaceDistance.allCases) { option in
                let on = race == option
                Button {
                    race = option
                    distanceText = presetText(option)
                } label: {
                    Text(option.label)
                        .font(.lbBody(13, .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(on ? LB.accent : LB.textBright)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: LB.rPill, style: .continuous)
                                .fill(on ? LB.accentTint() : LB.surfaceTile)
                        )
                }
                // Without a style of their own, every button in a list row
                // fires when the row is tapped.
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    /// The worked-out value, or what is still needed for it.
    @ViewBuilder
    private func answerRow(_ value: String?, unit: String?) -> some View {
        if let value {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.lbMono(30, .semibold))
                    .foregroundStyle(LB.accent)
                if let unit {
                    Text(unit)
                        .font(.lbBody(15))
                        .foregroundStyle(LB.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(hint)
                .foregroundStyle(LB.textMuted)
        }
    }

    private var hint: String {
        switch unknown {
        case .pace: "Enter a distance and a time."
        case .time: "Enter a distance and a pace."
        case .distance: "Enter a time and a pace."
        }
    }

    private func part(_ text: Binding<String>, _ suffix: String, _ field: Field) -> some View {
        HStack(spacing: 4) {
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
                .focused($focus, equals: field)
            Text(suffix)
                .foregroundStyle(LB.textTertiary)
        }
    }

    private func splitRow(_ split: PaceCalculator.Split) -> some View {
        // A whole km or mile is named by its number and tagged when it is
        // also a checkpoint or the finish; a mark between two of them is
        // named for what it is and shows where it lies.
        let title: String
        var tag: String?
        var detail: String?
        if let count = split.unitCount {
            title = "\(count) \(units.distanceUnit)"
            tag = split.isFinish ? "Finish" : split.checkpoint
        } else if split.isFinish {
            title = "Finish"
        } else {
            title = split.checkpoint ?? ""
            detail = units.distance(meters: split.meters)
        }
        let marked = split.isFinish || split.checkpoint != nil

        return HStack(spacing: 10) {
            Text(title)
                .font(.lbBody(15, marked ? .semibold : .regular))
                .foregroundStyle(marked ? LB.textPrimary : LB.textBright)
            if let tag {
                LBStatusChip(text: tag, color: LB.accent)
            }
            if let detail {
                Text(detail)
                    .font(.lbMono(11))
                    .foregroundStyle(LB.textTertiary)
            }
            Spacer()
            Text(PaceCalculator.clock(split.seconds))
                .font(.lbMono(15, marked ? .semibold : .medium))
                .foregroundStyle(split.isFinish ? LB.accent : LB.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Input

    /// Meters in one of the athlete's units: 1000 or 1609.344.
    private var unitMeters: Double { units.meters(fromDistanceValue: 1) }

    private var enteredMeters: Double? {
        if let race { return race.meters }
        return Self.number(distanceText).map { units.meters(fromDistanceValue: $0) }
    }

    private var enteredSeconds: Double? {
        Self.duration(hoursText, minutesText, secondsText)
    }

    private var enteredSecondsPerKm: Double? {
        Self.duration("", paceMinutesText, paceSecondsText).map { $0 / (unitMeters / 1000) }
    }

    private var result: PaceCalculator.Result? {
        PaceCalculator.solve(
            for: unknown,
            meters: enteredMeters,
            seconds: enteredSeconds,
            secondsPerKm: enteredSecondsPerKm
        )
    }

    /// The value that was being worked out becomes an input when the choice
    /// moves on, so fill its field with the answer it had. Without this,
    /// going from Pace to Time would ask for a pace the screen just showed.
    private func carryOver(from old: PaceCalculator.Unknown) {
        guard let last = PaceCalculator.solve(
            for: old,
            meters: enteredMeters,
            seconds: enteredSeconds,
            secondsPerKm: enteredSecondsPerKm
        ) else { return }
        switch old {
        case .distance:
            race = nil
            distanceText = Self.text(units.distanceValue(meters: last.meters), decimals: 2)
        case .time:
            let total = Int(last.seconds.rounded())
            hoursText = total >= 3600 ? String(total / 3600) : ""
            minutesText = String(total % 3600 / 60)
            secondsText = String(format: "%02d", total % 60)
        case .pace:
            let perUnit = Int((last.secondsPerKm * unitMeters / 1000).rounded())
            paceMinutesText = String(perUnit / 60)
            paceSecondsText = String(format: "%02d", perUnit % 60)
        }
    }

    /// A preset's distance the way it is said: 21.1 km, 13.11 mi.
    private func presetText(_ race: RaceDistance) -> String {
        Self.text(units.distanceValue(meters: race.meters), decimals: units == .imperial ? 2 : 1)
    }

    /// Accepts a decimal comma as well as a point.
    private static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }

    /// Hours, minutes and seconds as typed, in seconds. An empty part counts
    /// as zero; nil when nothing is filled in or a part is not a number.
    private static func duration(_ hours: String, _ minutes: String, _ seconds: String) -> Double? {
        var total = 0
        for (text, weight) in [(hours, 3600), (minutes, 60), (seconds, 1)] {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let value = Int(trimmed), (0...100_000).contains(value) else { return nil }
            total += value * weight
        }
        return total > 0 ? Double(total) : nil
    }

    /// At most `decimals` places, without trailing zeros: "10", "21.1".
    private static func text(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }
}

#Preview {
    NavigationStack {
        PaceCalculatorView()
    }
    .preferredColorScheme(.dark)
}
