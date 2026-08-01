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

    private var observerQueries: [(query: HKObserverQuery, type: HKSampleType)] = []
    /// The domain set the live observers were registered for, so a repeat call
    /// with the same consent is free and a changed one rebuilds.
    private var activeDomains: DataDomains?

    init(workoutManager: WorkoutManager, healthMetricsSyncer: HealthMetricsSyncer) {
        self.workoutManager = workoutManager
        self.healthMetricsSyncer = healthMetricsSyncer
    }

    /// Registers observer queries and enables background delivery for the
    /// consented domains only — iOS should never wake us for data the athlete
    /// hasn't shared, since the sync path would discard it anyway.
    ///
    /// Safe to call repeatedly. Call it again whenever consent changes: a
    /// different domain set tears the old observers down and rebuilds.
    func setUp(domains: DataDomains) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard domains != activeDomains else { return }

        await tearDown()
        activeDomains = domains
        isActive = true

        for domain in domains.elements {
            for (type, frequency) in domain.observedTypes {
                // Workouts drive extraction; everything else drives the metrics
                // pass, which re-reads its whole window and so doesn't care
                // which type woke it.
                let isWorkout = domain == .training
                await enableObserver(for: type, frequency: frequency) { [weak self] in
                    guard let self else { return }
                    if isWorkout {
                        AppLog.health.info("New workout detected, extracting")
                        await self.workoutManager.extractNewWorkouts()
                    } else {
                        AppLog.health.info("Health data updated (\(type.identifier, privacy: .public)), syncing metrics")
                        try? await self.healthMetricsSyncer.syncMetrics()
                    }
                }
            }
        }

        AppLog.health.info("Registered \(self.observerQueries.count) background observers for \(domains.wireValues.joined(separator: ", "), privacy: .public)")
    }

    /// Stops every live observer and hands background delivery back to iOS.
    /// Withdrawing consent has to reach this far — a still-registered observer
    /// keeps waking the app for data it no longer has any right to read.
    func tearDown() async {
        for (query, type) in observerQueries {
            healthStore.stop(query)
            try? await healthStore.disableBackgroundDelivery(for: type)
        }
        observerQueries.removeAll()
        activeDomains = nil
        isActive = false
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
        // Kept with its type so `tearDown` can hand background delivery back.
        observerQueries.append((query, sampleType))
    }
}
