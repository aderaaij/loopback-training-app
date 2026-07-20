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
        List {
            headerSection

            switch scheduled.plan.workout {
            case .custom(let custom):
                customWorkoutSections(custom)
            case .goal(let goal):
                goalWorkoutSection(goal)
            case .pacer(let pacer):
                pacerWorkoutSection(pacer)
            case .swimBikeRun:
                Section("Workout") {
                    Text("Swim-Bike-Run Workout")
                }
            @unknown default:
                Section("Workout") {
                    Text("Workout details unavailable")
                }
            }
        }
        .lbList()
        .navigationTitle(workoutName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerSection: some View {
        Section {
            LabeledContent("Type", value: activityName)
            if let dateString = formattedDate {
                LabeledContent("Scheduled", value: dateString)
            }
            LabeledContent("Status", value: scheduled.complete ? "Completed" : "Upcoming")
        }
    }

    // MARK: - Custom Workout

    @ViewBuilder
    private func customWorkoutSections(_ custom: CustomWorkout) -> some View {
        if let warmup = custom.warmup {
            Section("Warmup") {
                stepRow(goal: warmup.goal, alert: warmup.alert)
            }
        }

        ForEach(Array(custom.blocks.enumerated()), id: \.offset) { index, block in
            Section(blockHeader(index: index, block: block)) {
                ForEach(Array(block.steps.enumerated()), id: \.offset) { stepIndex, intervalStep in
                    intervalStepRow(intervalStep, stepNumber: stepIndex + 1)
                }
            }
        }

        if let cooldown = custom.cooldown {
            Section("Cooldown") {
                stepRow(goal: cooldown.goal, alert: cooldown.alert)
            }
        }
    }

    // MARK: - Goal Workout

    @ViewBuilder
    private func goalWorkoutSection(_ goal: SingleGoalWorkout) -> some View {
        Section("Goal") {
            LabeledContent("Activity", value: goal.activity.displayName)
            goalRow(goal.goal)
        }
    }

    // MARK: - Pacer Workout

    @ViewBuilder
    private func pacerWorkoutSection(_ pacer: PacerWorkout) -> some View {
        Section("Pacer") {
            LabeledContent("Activity", value: pacer.activity.displayName)
            LabeledContent("Distance", value: formatMeasurement(pacer.distance))
            LabeledContent("Time", value: formatDuration(pacer.time))
            LabeledContent("Pace", value: formatPace(distance: pacer.distance, time: pacer.time))
        }
    }

    // MARK: - Interval Step Row

    private func intervalStepRow(_ intervalStep: IntervalStep, stepNumber: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                purposeLabel(intervalStep.purpose)
                Spacer()
                Text(formatGoal(intervalStep.step.goal))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let alert = intervalStep.step.alert {
                alertLabel(alert)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Simple Step Row (warmup/cooldown)

    private func stepRow(goal: WorkoutGoal, alert: (any WorkoutAlert)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            goalRow(goal)

            if let alert {
                alertLabel(alert)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Goal Display

    private func goalRow(_ goal: WorkoutGoal) -> some View {
        LabeledContent("Goal", value: formatGoal(goal))
    }

    // MARK: - Purpose Label

    private func purposeLabel(_ purpose: IntervalStep.Purpose) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(purpose == .work ? LB.red : LB.blue)
                .frame(width: 8, height: 8)
            Text(purpose == .work ? "Work" : "Recovery")
                .font(.subheadline.weight(.medium))
        }
    }

    // MARK: - Alert Label

    private func alertLabel(_ alert: any WorkoutAlert) -> some View {
        HStack(spacing: 4) {
            Image(systemName: alertIconName(alert))
                .font(.caption)
                .foregroundStyle(LB.amber)
            Text(formatAlert(alert))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Block Header

    private func blockHeader(index: Int, block: IntervalBlock) -> String {
        if block.iterations > 1 {
            return "Block \(index + 1) — \(block.iterations)x"
        }
        return "Block \(index + 1)"
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
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .short
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: seconds) ?? formatMeasurement(measurement)
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
