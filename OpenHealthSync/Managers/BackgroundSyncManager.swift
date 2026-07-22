//
//  BackgroundSyncManager.swift
//  OpenHealthSync
//
//  Created by Claude on 04/04/2026.
//

import Foundation
import Observation
import HealthKit
import os

/// Registers HealthKit background delivery observers so that new workouts
/// and health data trigger automatic extraction and upload to the Training API.
@MainActor
@Observable
class BackgroundSyncManager {
    private(set) var isActive = false
    private let healthStore = HKHealthStore()
    private let workoutManager: WorkoutManager
    private let healthMetricsSyncer: HealthMetricsSyncer

    private var observerQueries: [HKObserverQuery] = []
    private var isSetUp = false

    init(workoutManager: WorkoutManager, healthMetricsSyncer: HealthMetricsSyncer) {
        self.workoutManager = workoutManager
        self.healthMetricsSyncer = healthMetricsSyncer
    }

    /// Call once after HealthKit authorization. Registers observer queries
    /// and enables background delivery for workouts and key health metrics.
    func setUp() async {
        guard !isSetUp else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        isSetUp = true
        isActive = true

        // Observe new workouts
        await enableObserver(
            for: HKWorkoutType.workoutType(),
            frequency: .immediate
        ) { [weak self] in
            guard let self else { return }
            AppLog.health.info("New workout detected, extracting")
            await self.workoutManager.extractNewWorkouts()
        }

        // Observe key health metrics that change daily
        let healthTypes: [(HKSampleType, HKUpdateFrequency)] = [
            (HKCategoryType(.sleepAnalysis), .hourly),
            (HKQuantityType(.restingHeartRate), .hourly),
            (HKQuantityType(.heartRateVariabilitySDNN), .hourly),
            (HKQuantityType(.bodyMass), .immediate),
            (HKQuantityType(.stepCount), .hourly),
            (HKQuantityType(.activeEnergyBurned), .hourly),
        ]

        for (type, frequency) in healthTypes {
            await enableObserver(for: type, frequency: frequency) { [weak self] in
                guard let self else { return }
                AppLog.health.info("Health data updated (\(type.identifier, privacy: .public)), syncing metrics")
                try? await self.healthMetricsSyncer.syncMetrics()
            }
        }

        AppLog.health.info("Registered \(self.observerQueries.count) background observers")
    }

    // MARK: - Private

    private func enableObserver(
        for sampleType: HKSampleType,
        frequency: HKUpdateFrequency,
        handler: @escaping @Sendable () async -> Void
    ) async {
        // Enable background delivery so iOS wakes us for updates
        do {
            try await healthStore.enableBackgroundDelivery(for: sampleType, frequency: frequency)
        } catch {
            AppLog.health.error("Failed to enable background delivery for \(sampleType.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        // Register observer query
        let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
            if let error {
                AppLog.health.error("Observer error for \(sampleType.identifier, privacy: .public): \(String(describing: error), privacy: .public)")
                completionHandler()
                return
            }

            Task {
                await handler()
                completionHandler()
            }
        }

        healthStore.execute(query)
        observerQueries.append(query)
    }
}
