//
//  WorkoutCompositionBuilder.swift
//  OpenHealthSync
//
//  Translates the server's QueuedWorkoutComposition wire format into a
//  WorkoutKit CustomWorkout. Pure string→enum mapping with defensive
//  defaults: unknown values fall back (open goal, running, work purpose)
//  rather than failing, so an older app tolerates newer server vocabulary.
//

import Foundation
import WorkoutKit
import HealthKit

nonisolated enum WorkoutCompositionBuilder {

    /// With `alertEvery`, distance steps in the main part of the workout are
    /// cut into steps of that length, so the watch taps at each one. Warmup
    /// and cooldown can only be one step each, and a step with a time goal
    /// has no distance to cut, so those stay whole.
    static func buildCustomWorkout(
        from composition: QueuedWorkoutComposition,
        alertEvery: DistanceAlert.Interval? = nil
    ) throws -> CustomWorkout {
        let activity = mapActivityType(composition.activityType)
        let location = mapLocation(composition.location)

        let warmup: WorkoutStep? = composition.warmup.map { step in
            WorkoutStep(goal: mapGoal(step.goal), alert: mapAlert(step.alert))
        }

        let blocks: [IntervalBlock] = composition.blocks.flatMap { block in
            intervalBlocks(for: block, alertEvery: alertEvery)
        }

        let cooldown: WorkoutStep? = composition.cooldown.map { step in
            WorkoutStep(goal: mapGoal(step.goal), alert: mapAlert(step.alert))
        }

        return CustomWorkout(
            activity: activity,
            location: location,
            displayName: composition.displayName,
            warmup: warmup,
            blocks: blocks,
            cooldown: cooldown
        )
    }

    // MARK: - Distance Alerts

    private static func intervalBlocks(
        for block: CompositionBlock,
        alertEvery: DistanceAlert.Interval?
    ) -> [IntervalBlock] {
        func step(_ source: CompositionIntervalStep, goal: WorkoutGoal? = nil) -> IntervalStep {
            IntervalStep(mapPurpose(source.purpose), goal: goal ?? mapGoal(source.goal), alert: mapAlert(source.alert))
        }
        func cut(_ source: CompositionIntervalStep) -> (full: Int, last: Double?)? {
            guard let alertEvery, source.goal.type == "distance", let value = source.goal.value else { return nil }
            let total = Measurement(value: value, unit: mapLengthUnit(source.goal.unit)).converted(to: .meters).value
            return DistanceAlert.cut(total: total, every: alertEvery.meters)
        }
        guard let alertEvery else {
            return [IntervalBlock(steps: block.steps.map { step($0) }, iterations: block.iterations)]
        }
        let every = WorkoutGoal.distance(alertEvery.value, alertEvery.unit)
        func lastGoal(_ meters: Double) -> WorkoutGoal {
            .distance(meters.rounded(), .meters)
        }

        // A plain run: one step, once. Repeating the short step reads better
        // on the watch ("3 of 8") than eight separate steps.
        if block.steps.count == 1, block.iterations == 1, let source = block.steps.first, let pieces = cut(source) {
            var result = [IntervalBlock(steps: [step(source, goal: every)], iterations: pieces.full)]
            if let last = pieces.last {
                result.append(IntervalBlock(steps: [step(source, goal: lastGoal(last))], iterations: 1))
            }
            return result
        }

        // Repeats can't nest, so inside a repeated block the pieces of a
        // long step follow each other.
        let steps: [IntervalStep] = block.steps.flatMap { source -> [IntervalStep] in
            guard let pieces = cut(source) else { return [step(source)] }
            var result = Array(repeating: step(source, goal: every), count: pieces.full)
            if let last = pieces.last {
                result.append(step(source, goal: lastGoal(last)))
            }
            return result
        }
        return [IntervalBlock(steps: steps, iterations: block.iterations)]
    }

    // MARK: - Mapping Helpers

    private static func mapGoal(_ goal: CompositionGoal) -> WorkoutGoal {
        switch goal.type {
        case "distance":
            guard let value = goal.value else { return .open }
            let unit = mapLengthUnit(goal.unit)
            return .distance(value, unit)
        case "time":
            guard let value = goal.value else { return .open }
            let unit = mapDurationUnit(goal.unit)
            return .time(value, unit)
        case "energy":
            guard let value = goal.value else { return .open }
            let unit = mapEnergyUnit(goal.unit)
            return .energy(value, unit)
        default:
            return .open
        }
    }

    private static func mapAlert(_ alert: CompositionAlert?) -> (any WorkoutAlert)? {
        guard let alert else { return nil }

        switch alert.type {
        case "speed":
            guard let min = alert.min, let max = alert.max else { return nil }
            let unit = mapSpeedUnit(alert.unit)
            return SpeedRangeAlert(
                target: Measurement(value: min, unit: unit)...Measurement(value: max, unit: unit),
                metric: .current
            )
        case "heartRate":
            guard let min = alert.min, let max = alert.max else { return nil }
            return HeartRateRangeAlert.heartRate(min...max)
        case "heartRateZone":
            guard let zone = alert.zone else { return nil }
            return HeartRateZoneAlert(zone: zone)
        case "cadence":
            guard let min = alert.min, let max = alert.max else { return nil }
            return CadenceRangeAlert.cadence(min...max)
        case "power":
            guard let min = alert.min, let max = alert.max else { return nil }
            return PowerRangeAlert.power(min...max, unit: .watts)
        case "powerZone":
            guard let zone = alert.zone else { return nil }
            return PowerZoneAlert.power(zone: zone)
        default:
            return nil
        }
    }

    private static func mapPurpose(_ purpose: String) -> IntervalStep.Purpose {
        switch purpose {
        case "work": return .work
        case "recovery": return .recovery
        default: return .work
        }
    }

    private static func mapActivityType(_ type: String) -> HKWorkoutActivityType {
        switch type {
        case "running": return .running
        case "cycling": return .cycling
        case "walking": return .walking
        case "hiking": return .hiking
        case "swimming": return .swimming
        default: return .running
        }
    }

    private static func mapLocation(_ location: String) -> HKWorkoutSessionLocationType {
        switch location {
        case "outdoor": return .outdoor
        case "indoor": return .indoor
        default: return .unknown
        }
    }

    private static func mapLengthUnit(_ unit: String?) -> UnitLength {
        switch unit {
        case "meters": return .meters
        case "kilometers": return .kilometers
        case "miles": return .miles
        default: return .meters
        }
    }

    private static func mapDurationUnit(_ unit: String?) -> UnitDuration {
        switch unit {
        case "seconds": return .seconds
        case "minutes": return .minutes
        default: return .seconds
        }
    }

    private static func mapEnergyUnit(_ unit: String?) -> UnitEnergy {
        switch unit {
        case "kilocalories": return .kilocalories
        default: return .kilocalories
        }
    }

    private static func mapSpeedUnit(_ unit: String?) -> UnitSpeed {
        switch unit {
        case "metersPerSecond": return .metersPerSecond
        case "kilometersPerHour": return .kilometersPerHour
        default: return .metersPerSecond
        }
    }
}
