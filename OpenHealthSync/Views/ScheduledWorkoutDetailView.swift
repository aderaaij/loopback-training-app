//
//  ScheduledWorkoutDetailView.swift
//  OpenHealthSync
//
//  Displays detailed breakdown of a scheduled workout plan:
//  warmup, interval blocks (work/recovery steps with goals and alerts),
//  and cooldown.
//

import SwiftUI
import WorkoutKit
import HealthKit

struct ScheduledWorkoutDetailView: View {
    let scheduled: ScheduledWorkoutPlan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                titleHeader

                switch scheduled.plan.workout {
                case .custom(let custom):
                    customWorkoutSections(custom)
                case .goal(let goal):
                    goalWorkoutSection(goal)
                case .pacer(let pacer):
                    pacerWorkoutSection(pacer)
                case .swimBikeRun:
                    unavailableSection(text: "Swim-Bike-Run Workout")
                @unknown default:
                    unavailableSection(text: "Workout details unavailable")
                }
            }
            .padding(18)
        }
        .background(LB.bg)
        .navigationTitle(workoutName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(workoutName)
                    .font(.lbDisplay(24, .bold))
                    .tracking(-0.6)
                    .foregroundStyle(LB.textPrimary)
                Spacer()
                LBStatusChip(
                    text: scheduled.complete ? "Completed" : "Upcoming",
                    color: scheduled.complete ? LB.green : LB.blue
                )
            }
            Text(metaLine)
                .font(.lbMono(11))
                .foregroundStyle(LB.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaLine: String {
        var parts = [activityName.uppercased()]
        if let formattedDate {
            parts.append(formattedDate.uppercased())
        }
        if let total = totalDuration {
            parts.append("\(total.partial ? "≥ " : "")\(formatSeconds(total.seconds).uppercased()) TOTAL")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Durations

    /// Seconds for a time-based goal; nil for open/distance/energy goals,
    /// whose duration we can't know up front.
    private func seconds(from goal: WorkoutGoal) -> TimeInterval? {
        if case .time(let value, let unit) = goal {
            return Measurement(value: value, unit: unit).converted(to: .seconds).value
        }
        return nil
    }

    /// Summed time of every step across all iterations. `partial` is true when
    /// any step has a non-time goal, so the total is a lower bound.
    private func blockDuration(_ block: IntervalBlock) -> (seconds: TimeInterval, partial: Bool) {
        var total: TimeInterval = 0
        var partial = false
        for step in block.steps {
            if let s = seconds(from: step.step.goal) {
                total += s
            } else {
                partial = true
            }
        }
        return (total * Double(block.iterations), partial)
    }

    private var totalDuration: (seconds: TimeInterval, partial: Bool)? {
        switch scheduled.plan.workout {
        case .custom(let custom):
            var total: TimeInterval = 0
            var partial = false
            if let warmup = custom.warmup {
                if let s = seconds(from: warmup.goal) { total += s } else { partial = true }
            }
            for block in custom.blocks {
                let d = blockDuration(block)
                total += d.seconds
                partial = partial || d.partial
            }
            if let cooldown = custom.cooldown {
                if let s = seconds(from: cooldown.goal) { total += s } else { partial = true }
            }
            return total > 0 ? (total, partial) : nil
        case .goal(let goal):
            return seconds(from: goal.goal).map { ($0, false) }
        case .pacer(let pacer):
            return (pacer.time.converted(to: .seconds).value, false)
        default:
            return nil
        }
    }

    private func blockTrailing(_ block: IntervalBlock) -> String? {
        let d = blockDuration(block)
        var parts: [String] = []
        if block.iterations > 1 {
            parts.append("\(block.iterations)×")
        }
        if d.seconds > 0 {
            parts.append("\(d.partial ? "≥ " : "")\(formatSeconds(d.seconds))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func unavailableSection(text: String) -> some View {
        LBDetailSection(title: "Workout") {
            Text(text)
                .font(.lbBody(14))
                .foregroundStyle(LB.textSecondary)
        }
    }

    // MARK: - Custom Workout

    @ViewBuilder
    private func customWorkoutSections(_ custom: CustomWorkout) -> some View {
        if let warmup = custom.warmup {
            LBDetailSection(title: "Warmup") {
                stepRow(goal: warmup.goal, alert: warmup.alert)
            }
        }

        ForEach(Array(custom.blocks.enumerated()), id: \.offset) { index, block in
            LBDetailSection(
                title: "Block \(index + 1)",
                trailing: blockTrailing(block)
            ) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(block.steps.enumerated()), id: \.offset) { stepIndex, intervalStep in
                        if stepIndex > 0 {
                            Rectangle().fill(LB.line).frame(height: 1)
                        }
                        intervalStepRow(intervalStep)
                    }
                }
            }
        }

        if let cooldown = custom.cooldown {
            LBDetailSection(title: "Cooldown") {
                stepRow(goal: cooldown.goal, alert: cooldown.alert)
            }
        }
    }

    // MARK: - Goal Workout

    private func goalWorkoutSection(_ goal: SingleGoalWorkout) -> some View {
        LBDetailSection(title: "Goal") {
            VStack(alignment: .leading, spacing: 10) {
                detailRow(label: "Activity", value: goal.activity.displayName)
                goalRow(goal.goal)
            }
        }
    }

    // MARK: - Pacer Workout

    private func pacerWorkoutSection(_ pacer: PacerWorkout) -> some View {
        LBDetailSection(title: "Pacer") {
            VStack(alignment: .leading, spacing: 10) {
                detailRow(label: "Activity", value: pacer.activity.displayName)
                detailRow(label: "Distance", value: formatMeasurement(pacer.distance))
                detailRow(label: "Time", value: formatDuration(pacer.time))
                detailRow(label: "Pace", value: formatPace(distance: pacer.distance, time: pacer.time))
            }
        }
    }

    // MARK: - Interval Step Row

    private func intervalStepRow(_ intervalStep: IntervalStep) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                purposeLabel(intervalStep.purpose)
                Spacer()
                Text(formatGoal(intervalStep.step.goal))
                    .font(.lbMono(12))
                    .foregroundStyle(LB.textBright)
            }

            if let alert = intervalStep.step.alert {
                alertLabel(alert)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: - Simple Step Row (warmup/cooldown)

    private func stepRow(goal: WorkoutGoal, alert: (any WorkoutAlert)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            goalRow(goal)

            if let alert {
                alertLabel(alert)
            }
        }
    }

    // MARK: - Labeled Rows

    private func goalRow(_ goal: WorkoutGoal) -> some View {
        detailRow(label: "Goal", value: formatGoal(goal))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.lbBody(14))
                .foregroundStyle(LB.textSecondary)
            Spacer()
            Text(value)
                .font(.lbMono(12))
                .foregroundStyle(LB.textBright)
        }
    }

    // MARK: - Purpose Label

    private func purposeLabel(_ purpose: IntervalStep.Purpose) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(purpose == .work ? LB.red : LB.blue)
                .frame(width: 8, height: 8)
            Text(purpose == .work ? "Work" : "Recovery")
                .font(.lbBody(14, .semibold))
                .foregroundStyle(LB.textPrimary)
        }
    }

    // MARK: - Alert Label

    private func alertLabel(_ alert: any WorkoutAlert) -> some View {
        HStack(spacing: 5) {
            Image(systemName: alertIconName(alert))
                .font(.system(size: 11))
                .foregroundStyle(LB.amber)
            Text(formatAlert(alert))
                .font(.lbMono(11))
                .foregroundStyle(LB.textTertiary)
        }
    }

    // MARK: - Formatting Helpers

    private func formatGoal(_ goal: WorkoutGoal) -> String {
        switch goal {
        case .open:
            return "Open"
        case .distance(let value, let unit):
            let measurement = Measurement(value: value, unit: unit)
            return formatMeasurement(measurement)
        case .time(let value, let unit):
            return formatDuration(Measurement(value: value, unit: unit))
        case .energy(let value, let unit):
            let measurement = Measurement(value: value, unit: unit)
            return formatMeasurement(measurement)
        case .poolSwimDistanceWithTime(let distance, let time):
            return "\(formatMeasurement(distance)) in \(formatDuration(time))"
        @unknown default:
            return "Unknown"
        }
    }

    /// Durations arrive from WorkoutKit in seconds; render them in the largest
    /// sensible units ("20 min", "1 hr, 15 min") instead of "1,200 sec".
    private func formatDuration(_ measurement: Measurement<UnitDuration>) -> String {
        let seconds = measurement.converted(to: .seconds).value
        return formatSeconds(seconds).isEmpty ? formatMeasurement(measurement) : formatSeconds(seconds)
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? ""
    }

    private func formatMeasurement<T: Dimension>(_ measurement: Measurement<T>) -> String {
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter.string(from: measurement)
    }

    private func formatAlert(_ alert: any WorkoutAlert) -> String {
        if let speedAlert = alert as? SpeedRangeAlert {
            let lower = speedAlert.target.lowerBound
            let upper = speedAlert.target.upperBound
            return "Speed: \(formatMeasurement(lower)) – \(formatMeasurement(upper))"
        } else if let hrAlert = alert as? HeartRateRangeAlert {
            let lower = hrAlert.target.lowerBound
            let upper = hrAlert.target.upperBound
            return "HR: \(formatMeasurement(lower)) – \(formatMeasurement(upper))"
        } else if let hrZone = alert as? HeartRateZoneAlert {
            return "HR Zone \(hrZone.zone)"
        } else if let cadenceAlert = alert as? CadenceRangeAlert {
            let lower = cadenceAlert.target.lowerBound
            let upper = cadenceAlert.target.upperBound
            return "Cadence: \(formatMeasurement(lower)) – \(formatMeasurement(upper))"
        } else if let powerAlert = alert as? PowerRangeAlert {
            let lower = powerAlert.target.lowerBound
            let upper = powerAlert.target.upperBound
            return "Power: \(formatMeasurement(lower)) – \(formatMeasurement(upper))"
        } else if let powerZone = alert as? PowerZoneAlert {
            return "Power Zone \(powerZone.zone)"
        }
        return "Alert active"
    }

    private func alertIconName(_ alert: any WorkoutAlert) -> String {
        if alert is SpeedRangeAlert {
            return "speedometer"
        } else if alert is HeartRateRangeAlert || alert is HeartRateZoneAlert {
            return "heart.fill"
        } else if alert is CadenceRangeAlert {
            return "metronome.fill"
        } else if alert is PowerRangeAlert || alert is PowerZoneAlert {
            return "bolt.fill"
        }
        return "bell.fill"
    }

    private func formatPace(distance: Measurement<UnitLength>, time: Measurement<UnitDuration>) -> String {
        let distanceKm = distance.converted(to: .kilometers).value
        let timeSeconds = time.converted(to: .seconds).value
        guard distanceKm > 0 else { return "--" }
        let paceSecondsPerKm = timeSeconds / distanceKm
        let minutes = Int(paceSecondsPerKm) / 60
        let seconds = Int(paceSecondsPerKm) % 60
        return "\(minutes):\(String(format: "%02d", seconds)) /km"
    }

    // MARK: - Computed Properties

    private var workoutName: String {
        switch scheduled.plan.workout {
        case .custom(let custom):
            return custom.displayName ?? "Custom Workout"
        case .goal(let goal):
            return "Goal: \(goal.activity.displayName)"
        case .pacer(let pacer):
            return "Pacer: \(pacer.activity.displayName)"
        case .swimBikeRun:
            return "Swim-Bike-Run"
        @unknown default:
            return "Workout"
        }
    }

    private var activityName: String {
        switch scheduled.plan.workout {
        case .custom(let custom):
            return custom.activity.displayName
        case .goal(let goal):
            return goal.activity.displayName
        case .pacer(let pacer):
            return pacer.activity.displayName
        case .swimBikeRun:
            return "Multisport"
        @unknown default:
            return "Unknown"
        }
    }

    private var formattedDate: String? {
        let dc = scheduled.date
        guard let year = dc.year, let month = dc.month, let day = dc.day else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = dc.hour
        components.minute = dc.minute
        guard let date = Calendar.current.date(from: components) else { return nil }
        return date.formatted(date: .abbreviated, time: dc.hour != nil ? .shortened : .omitted)
    }
}

// MARK: - HKWorkoutActivityType Display Name

extension HKWorkoutActivityType {
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .walking: return "Walking"
        case .hiking: return "Hiking"
        case .swimming: return "Swimming"
        case .functionalStrengthTraining: return "Strength"
        case .yoga: return "Yoga"
        case .coreTraining: return "Core Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .rowing: return "Rowing"
        case .crossTraining: return "Cross Training"
        case .elliptical: return "Elliptical"
        default: return "Workout"
        }
    }
}
