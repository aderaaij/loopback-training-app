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

    static func buildCustomWorkout(from composition: QueuedWorkoutComposition) throws -> CustomWorkout {
        let activity = mapActivityType(composition.activityType)
        let location = mapLocation(composition.location)

        let warmup: WorkoutStep? = composition.warmup.map { step in
            WorkoutStep(goal: mapGoal(step.goal), alert: mapAlert(step.alert))
        }

        let blocks: [IntervalBlock] = composition.blocks.map { block in
            let steps: [IntervalStep] = block.steps.map { step in
                IntervalStep(
                    mapPurpose(step.purpose),
                    goal: mapGoal(step.goal),
                    alert: mapAlert(step.alert)
                )
            }
            return IntervalBlock(steps: steps, iterations: block.iterations)
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
