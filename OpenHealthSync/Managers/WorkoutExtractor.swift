//
//  WorkoutExtractor.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 14/03/2026.
//

import Foundation
import HealthKit
import CoreLocation

actor WorkoutExtractor {
    private let healthStore = HKHealthStore()

    /// Max route points to send. Points beyond this are downsampled evenly.
    private let maxRoutePoints = 2000
    /// Max time series samples per metric. Longer workouts get downsampled.
    private let maxTimeSeriesSamples = 1800

    // MARK: - Main Extraction

    func extractWorkout(_ workout: HKWorkout, planWorkoutId: UUID? = nil) async throws -> DetailedWorkout {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let mps = HKUnit.meter().unitDivided(by: .second())

        // Fetch all data concurrently
        async let routePoints = fetchRoute(workout)
        async let heartRateData = fetchTimeSeries(
            workout, type: HKQuantityType(.heartRate), unit: bpm
        )
        async let cadenceData = fetchCadence(workout)
        async let powerData = fetchTimeSeries(
            workout, type: HKQuantityType(.runningPower), unit: .watt()
        )
        async let speedData = fetchTimeSeries(
            workout, type: HKQuantityType(.runningSpeed), unit: mps
        )
        async let strideLengthData = fetchTimeSeries(
            workout, type: HKQuantityType(.runningStrideLength), unit: .meter()
        )
        async let vertOscData = fetchTimeSeries(
            workout, type: HKQuantityType(.runningVerticalOscillation),
            unit: .meterUnit(with: .centi)
        )
        async let gctData = fetchTimeSeries(
            workout, type: HKQuantityType(.runningGroundContactTime),
            unit: .secondUnit(with: .milli)
        )
        async let effortScore = fetchEffortScore(
            workout, type: HKQuantityType(.workoutEffortScore)
        )
        async let estimatedEffortScore = fetchEffortScore(
            workout, type: HKQuantityType(.estimatedWorkoutEffortScore)
        )

        let route = try? await routePoints
        let hr = try? await heartRateData
        let cad = try? await cadenceData
        let pwr = try? await powerData
        let spd = try? await speedData
        let stride = try? await strideLengthData
        let vertOsc = try? await vertOscData
        let gct = try? await gctData
        let rpe = await effortScore
        let estRpe = await estimatedEffortScore

        let activities = extractActivities(workout)
        let events = extractEvents(workout)

        // Compute splits from full-resolution data before downsampling. Pause
        // intervals are subtracted so split pace/averages stay consistent with
        // workout.duration, which excludes paused time.
        let pauses = pauseIntervals(events: events, workoutEnd: workout.endDate)
        let splits = computeSplits(
            route: route ?? [], heartRate: hr, cadence: cad, power: pwr,
            pauses: pauses
        )

        // Downsample for the JSON payload
        let dsRoute = downsampleRoute(route)
        let dsHr = downsampleTimeSeries(hr)
        let dsCad = downsampleTimeSeries(cad)
        let dsPwr = downsampleTimeSeries(pwr)
        let dsSpd = downsampleTimeSeries(spd)
        let dsStride = downsampleTimeSeries(stride)
        let dsVertOsc = downsampleTimeSeries(vertOsc)
        let dsGct = downsampleTimeSeries(gct)

        // Map HK metadata to [String: String]
        var metadataDict: [String: String]?
        if let meta = workout.metadata {
            metadataDict = meta.reduce(into: [:]) { result, pair in
                result[pair.key] = "\(pair.value)"
            }
        }

        let activityType = activityTypeName(workout.workoutActivityType)

        return DetailedWorkout(
            id: workout.uuid,
            planWorkoutId: planWorkoutId,
            activityType: activityType,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            totalDistance: workout.statistics(for: HKQuantityType(.distanceWalkingRunning))?.sumQuantity()?.doubleValue(for: .meter()),
            totalEnergyBurned: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            source: workout.sourceRevision.source.bundleIdentifier,
            route: nilIfEmpty(dsRoute),
            heartRate: nilIfEmpty(dsHr),
            cadence: nilIfEmpty(dsCad),
            power: nilIfEmpty(dsPwr),
            speed: nilIfEmpty(dsSpd),
            strideLength: nilIfEmpty(dsStride),
            verticalOscillation: nilIfEmpty(dsVertOsc),
            groundContactTime: nilIfEmpty(dsGct),
            splits: splits?.isEmpty == true ? nil : splits,
            activities: activities?.isEmpty == true ? nil : activities,
            events: events?.isEmpty == true ? nil : events,
            metadata: metadataDict,
            effortScore: rpe,
            estimatedEffortScore: estRpe
        )
    }

    // MARK: - Effort Score

    /// Reads the most recent effort score sample linked to this workout via
    /// HKWorkoutEffortRelationship. Returns nil when no rating exists (user
    /// skipped the watchOS prompt, or for workouts predating iOS 18).
    private func fetchEffortScore(_ workout: HKWorkout, type: HKQuantityType) async -> Double? {
        let predicate = HKQuery.predicateForWorkoutEffortSamplesRelated(workout: workout, activity: nil)
        return await withCheckedContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?
                    .quantity.doubleValue(for: .appleEffortScore())
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    private func nilIfEmpty(_ array: [TimeSeries]?) -> [TimeSeries]? {
        guard let arr = array, !arr.isEmpty else { return nil }
        return arr
    }

    private func nilIfEmpty(_ array: [RoutePoint]?) -> [RoutePoint]? {
        guard let arr = array, !arr.isEmpty else { return nil }
        return arr
    }

    // MARK: - Downsampling

    /// Evenly downsample route points, always keeping first and last.
    private func downsampleRoute(_ points: [RoutePoint]?) -> [RoutePoint]? {
        guard let points, points.count > maxRoutePoints else { return points }
        return evenlySubsample(points, target: maxRoutePoints)
    }

    /// Evenly downsample time series, always keeping first and last.
    private func downsampleTimeSeries(_ series: [TimeSeries]?) -> [TimeSeries]? {
        guard let series, series.count > maxTimeSeriesSamples else { return series }
        return evenlySubsample(series, target: maxTimeSeriesSamples)
    }

    /// Picks `target` evenly spaced elements from `array`, always including
    /// the first and last element for correct time bounds.
    private func evenlySubsample<T>(_ array: [T], target: Int) -> [T] {
        guard array.count > target, target >= 2 else { return array }
        var result: [T] = []
        result.reserveCapacity(target)
        let step = Double(array.count - 1) / Double(target - 1)
        for i in 0..<target {
            let index = Int((Double(i) * step).rounded())
            result.append(array[index])
        }
        return result
    }

    // MARK: - Route

    private func fetchRoute(_ workout: HKWorkout) async throws -> [RoutePoint] {
        let routeType = HKSeriesType.workoutRoute()
        let samples = try await fetchSamples(for: workout, type: routeType)

        guard let route = samples.first as? HKWorkoutRoute else {
            return []
        }

        let descriptor = HKWorkoutRouteQueryDescriptor(route)
        var points: [RoutePoint] = []

        for try await location in descriptor.results(for: healthStore) {
            points.append(RoutePoint(
                timestamp: location.timestamp,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitude: location.altitude,
                speed: location.speed,
                course: location.course,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy
            ))
        }

        return points
    }

    // MARK: - Cadence (steps/min from stepCount)

    private func fetchCadence(_ workout: HKWorkout) async throws -> [TimeSeries] {
        let stepType = HKQuantityType(.stepCount)
        let samples = try await fetchSamples(for: workout, type: stepType)
        var result: [TimeSeries] = []

        for sample in samples {
            guard let qs = sample as? HKQuantitySample else { continue }
            let steps = qs.quantity.doubleValue(for: .count())
            let duration = qs.endDate.timeIntervalSince(qs.startDate)
            guard duration > 0 else { continue }
            let stepsPerMin = (steps / duration) * 60.0
            result.append(TimeSeries(
                timestamp: qs.startDate,
                value: stepsPerMin
            ))
        }

        return result.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Time Series

    private func fetchTimeSeries(
        _ workout: HKWorkout,
        type: HKQuantityType,
        unit: HKUnit
    ) async throws -> [TimeSeries] {
        let samples = try await fetchSamples(for: workout, type: type)
        var result: [TimeSeries] = []

        for sample in samples {
            guard let quantitySample = sample as? HKQuantitySample else { continue }

            if quantitySample.count > 1 {
                // Expand series data
                let seriesEntries = try await expandSeries(
                    sample: quantitySample, type: type, unit: unit
                )
                result.append(contentsOf: seriesEntries)
            } else {
                result.append(TimeSeries(
                    timestamp: quantitySample.startDate,
                    value: quantitySample.quantity.doubleValue(for: unit)
                ))
            }
        }

        return result.sorted { $0.timestamp < $1.timestamp }
    }

    private func expandSeries(
        sample: HKQuantitySample,
        type: HKQuantityType,
        unit: HKUnit
    ) async throws -> [TimeSeries] {
        let objectPredicate = HKQuery.predicateForObject(with: sample.uuid)
        let predicate = HKSamplePredicate.quantitySample(
            type: type, predicate: objectPredicate
        )
        let descriptor = HKQuantitySeriesSampleQueryDescriptor(
            predicate: predicate,
            options: .orderByQuantitySampleStartDate
        )

        var entries: [TimeSeries] = []
        for try await entry in descriptor.results(for: healthStore) {
            entries.append(TimeSeries(
                timestamp: entry.dateInterval.start,
                value: entry.quantity.doubleValue(for: unit)
            ))
        }
        return entries
    }

    // MARK: - Pause Intervals

    /// Wall-clock intervals during which the workout was paused, from paired
    /// pause/resume and motionPaused/motionResumed events. Auto-pause stops
    /// Apple's duration clock just like a manual pause, so both pairs count.
    /// pauseOrResumeRequest is a button press, not a state change, and is
    /// ignored. An unmatched trailing pause runs to the workout's end.
    func pauseIntervals(events: [WorkoutEventData]?, workoutEnd: Date) -> [DateInterval] {
        guard let events, !events.isEmpty else { return [] }

        var intervals: [DateInterval] = []
        var manualStart: Date?
        var motionStart: Date?

        for event in events.sorted(by: { $0.startDate < $1.startDate }) {
            switch event.type {
            case "pause":
                if manualStart == nil { manualStart = event.startDate }
            case "resume":
                if let start = manualStart, event.startDate > start {
                    intervals.append(DateInterval(start: start, end: event.startDate))
                }
                manualStart = nil
            case "motionPaused":
                if motionStart == nil { motionStart = event.startDate }
            case "motionResumed":
                if let start = motionStart, event.startDate > start {
                    intervals.append(DateInterval(start: start, end: event.startDate))
                }
                motionStart = nil
            default:
                break
            }
        }

        if let start = manualStart, workoutEnd > start {
            intervals.append(DateInterval(start: start, end: workoutEnd))
        }
        if let start = motionStart, workoutEnd > start {
            intervals.append(DateInterval(start: start, end: workoutEnd))
        }

        return mergeIntervals(intervals)
    }

    /// Merges overlapping or touching intervals (a manual pause inside an
    /// auto-pause must not be counted twice).
    private func mergeIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        guard intervals.count > 1 else { return intervals }
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged = [sorted[0]]
        for interval in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(
                    start: last.start, end: max(last.end, interval.end)
                )
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    /// Total overlap of [start, end] with the pause intervals.
    private func pausedDuration(from start: Date, to end: Date, pauses: [DateInterval]) -> TimeInterval {
        pauses.reduce(0) { total, pause in
            let overlap = min(end, pause.end).timeIntervalSince(max(start, pause.start))
            return total + max(0, overlap)
        }
    }

    // MARK: - Splits

    func computeSplits(
        route: [RoutePoint],
        heartRate: [TimeSeries]?,
        cadence: [TimeSeries]?,
        power: [TimeSeries]?,
        pauses: [DateInterval] = []
    ) -> [Split]? {
        guard route.count >= 2 else { return nil }

        var splits: [Split] = []
        var splitStartIndex = 0
        var accumulatedDistance: Double = 0
        let splitDistance: Double = 1000 // meters

        for i in 1..<route.count {
            let prev = CLLocation(latitude: route[i - 1].latitude, longitude: route[i - 1].longitude)
            let curr = CLLocation(latitude: route[i].latitude, longitude: route[i].longitude)
            accumulatedDistance += curr.distance(from: prev)

            if accumulatedDistance >= splitDistance {
                let split = buildSplit(
                    index: splits.count + 1,
                    route: route,
                    from: splitStartIndex,
                    to: i,
                    distance: accumulatedDistance,
                    heartRate: heartRate,
                    cadence: cadence,
                    power: power,
                    pauses: pauses
                )
                splits.append(split)
                accumulatedDistance = 0
                splitStartIndex = i
            }
        }

        // Final partial split (only if meaningful distance)
        if accumulatedDistance > 50 {
            let split = buildSplit(
                index: splits.count + 1,
                route: route,
                from: splitStartIndex,
                to: route.count - 1,
                distance: accumulatedDistance,
                heartRate: heartRate,
                cadence: cadence,
                power: power,
                pauses: pauses
            )
            splits.append(split)
        }

        return splits
    }

    private func buildSplit(
        index: Int,
        route: [RoutePoint],
        from startIdx: Int,
        to endIdx: Int,
        distance: Double,
        heartRate: [TimeSeries]?,
        cadence: [TimeSeries]?,
        power: [TimeSeries]?,
        pauses: [DateInterval]
    ) -> Split {
        let splitStart = route[startIdx].timestamp
        let splitEnd = route[endIdx].timestamp
        // Moving time, not wall-clock: paused time inside the split would
        // otherwise inflate its duration and pace (startDate/endDate stay
        // wall-clock bounds for charts).
        let paused = pausedDuration(from: splitStart, to: splitEnd, pauses: pauses)
        let duration = max(0, splitEnd.timeIntervalSince(splitStart) - paused)
        let pace = distance > 0 ? duration / (distance / 1000) : 0

        // Elevation gain/loss from route altitude data
        var elevGain: Double = 0
        var elevLoss: Double = 0
        for i in (startIdx + 1)...endIdx {
            let delta = route[i].altitude - route[i - 1].altitude
            if delta > 0 { elevGain += delta }
            else { elevLoss += abs(delta) }
        }

        return Split(
            index: index,
            distance: distance,
            duration: duration,
            pace: pace,
            averageHeartRate: averageTimeSeries(heartRate, from: splitStart, to: splitEnd, excluding: pauses),
            averageCadence: averageTimeSeries(cadence, from: splitStart, to: splitEnd, excluding: pauses),
            averagePower: averageTimeSeries(power, from: splitStart, to: splitEnd, excluding: pauses),
            elevationGain: elevGain > 0 ? elevGain : nil,
            elevationLoss: elevLoss > 0 ? elevLoss : nil,
            startDate: splitStart,
            endDate: splitEnd
        )
    }

    private func averageTimeSeries(
        _ series: [TimeSeries]?,
        from start: Date,
        to end: Date,
        excluding pauses: [DateInterval] = []
    ) -> Double? {
        guard let data = series else { return nil }
        // HR keeps sampling through a pause (recovering values), so paused
        // samples must not drag the split average below the running value.
        let inRange = data.filter { sample in
            sample.timestamp >= start && sample.timestamp <= end
                && !pauses.contains { $0.contains(sample.timestamp) }
        }
        guard !inRange.isEmpty else { return nil }
        return inRange.reduce(0.0) { $0 + $1.value } / Double(inRange.count)
    }

    // MARK: - Activities (intervals / multisport segments)

    func extractActivities(_ workout: HKWorkout) -> [WorkoutActivityData]? {
        let activities = workout.workoutActivities
        guard !activities.isEmpty else { return nil }

        let bpm = HKUnit.count().unitDivided(by: .minute())

        return activities.compactMap { activity in
            guard let endDate = activity.endDate else { return nil }

            let distance = activity.statistics(for: HKQuantityType(.distanceWalkingRunning))?
                .sumQuantity()?.doubleValue(for: .meter())
            let energy = activity.statistics(for: HKQuantityType(.activeEnergyBurned))?
                .sumQuantity()?.doubleValue(for: .kilocalorie())
            let avgHR = activity.statistics(for: HKQuantityType(.heartRate))?
                .averageQuantity()?.doubleValue(for: bpm)

            let activityType = activityTypeName(activity.workoutConfiguration.activityType)

            // Extract events scoped to this activity
            let activityEvents: [WorkoutEventData]? = activity.workoutEvents.isEmpty ? nil :
                activity.workoutEvents.map { event in
                    let typeName: String
                    switch event.type {
                    case .pause: typeName = "pause"
                    case .resume: typeName = "resume"
                    case .lap: typeName = "lap"
                    case .segment: typeName = "segment"
                    case .marker: typeName = "marker"
                    case .motionPaused: typeName = "motionPaused"
                    case .motionResumed: typeName = "motionResumed"
                    case .pauseOrResumeRequest: typeName = "pauseOrResumeRequest"
                    @unknown default: typeName = "unknown"
                    }
                    var metaDict: [String: String]?
                    if let meta = event.metadata {
                        metaDict = meta.reduce(into: [:]) { r, p in r[p.key] = "\(p.value)" }
                    }
                    return WorkoutEventData(
                        type: typeName,
                        startDate: event.dateInterval.start,
                        endDate: event.dateInterval.end,
                        metadata: metaDict
                    )
                }

            // Activity-level metadata
            var metaDict: [String: String]?
            if let meta = activity.metadata {
                metaDict = meta.reduce(into: [:]) { r, p in r[p.key] = "\(p.value)" }
            }

            return WorkoutActivityData(
                activityType: activityType,
                startDate: activity.startDate,
                endDate: endDate,
                duration: activity.duration,
                totalDistance: distance,
                totalEnergyBurned: energy,
                averageHeartRate: avgHR,
                events: activityEvents,
                metadata: metaDict
            )
        }
    }

    // MARK: - Events

    func extractEvents(_ workout: HKWorkout) -> [WorkoutEventData]? {
        guard let events = workout.workoutEvents, !events.isEmpty else { return nil }

        return events.map { event in
            let typeName: String
            switch event.type {
            case .pause: typeName = "pause"
            case .resume: typeName = "resume"
            case .lap: typeName = "lap"
            case .segment: typeName = "segment"
            case .marker: typeName = "marker"
            case .motionPaused: typeName = "motionPaused"
            case .motionResumed: typeName = "motionResumed"
            case .pauseOrResumeRequest: typeName = "pauseOrResumeRequest"
            @unknown default: typeName = "unknown"
            }

            var metaDict: [String: String]?
            if let meta = event.metadata {
                metaDict = meta.reduce(into: [:]) { result, pair in
                    result[pair.key] = "\(pair.value)"
                }
            }

            return WorkoutEventData(
                type: typeName,
                startDate: event.dateInterval.start,
                endDate: event.dateInterval.end,
                metadata: metaDict
            )
        }
    }

    // MARK: - Helpers

    private func fetchSamples(
        for workout: HKWorkout,
        type: HKSampleType
    ) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let sort = NSSortDescriptor(
                key: HKSampleSortIdentifierStartDate, ascending: true
            )
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            self.healthStore.execute(query)
        }
    }

    private func activityTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .hiking: return "hiking"
        case .swimming: return "swimming"
        case .crossTraining: return "crossTraining"
        case .functionalStrengthTraining: return "functionalStrength"
        case .traditionalStrengthTraining: return "traditionalStrength"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stairClimbing"
        case .highIntensityIntervalTraining: return "hiit"
        case .coreTraining: return "coreTraining"
        case .flexibility: return "flexibility"
        case .cooldown: return "cooldown"
        case .mixedCardio: return "mixedCardio"
        case .cardioDance: return "cardioDance"
        case .mindAndBody: return "mindAndBody"
        case .play: return "play"
        case .other: return "other"
        case .socialDance: return "socialDance"
        case .fitnessGaming: return "fitnessGaming"
        case .downhillSkiing: return "downhillSkiing"
        case .crossCountrySkiing: return "crossCountrySkiing"
        case .snowboarding: return "snowboarding"
        case .surfingSports: return "surfing"
        case .tennis: return "tennis"
        case .soccer: return "soccer"
        case .basketball: return "basketball"
        case .boxing: return "boxing"
        case .kickboxing: return "kickboxing"
        case .martialArts: return "martialArts"
        case .climbing: return "climbing"
        case .jumpRope: return "jumpRope"
        case .golf: return "golf"
        default: return "other(\(type.rawValue))"
        }
    }
}
