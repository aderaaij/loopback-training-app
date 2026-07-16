//
//  HealthMetricsModels.swift
//  OpenHealthSync
//
//  Created by Claude on 04/04/2026.
//

import Foundation

// MARK: - Daily Health Metrics

struct DailyHealthMetrics: Codable, Sendable {
    let date: String                        // "2026-04-04" (ISO date, no time)
    let sleepDuration: Double?              // seconds
    let sleepStages: SleepStages?
    let restingHeartRate: Double?           // bpm
    let hrvSdnn: Double?                    // ms
    let weight: Double?                     // kg
    let vo2Max: Double?                     // mL/kg/min
    let steps: Int?
    let activeEnergyBurned: Double?         // kcal
    let bodyFatPercentage: Double?          // 0-100
    let leanBodyMass: Double?               // kg
    let respiratoryRate: Double?            // breaths/min
    let spo2: Double?                       // 0-100 percentage

    enum CodingKeys: String, CodingKey {
        case date
        case sleepDuration = "sleep_duration"
        case sleepStages = "sleep_stages"
        case restingHeartRate = "resting_heart_rate"
        case hrvSdnn = "hrv_sdnn"
        case weight
        case vo2Max = "vo2_max"
        case steps
        case activeEnergyBurned = "active_energy_burned"
        case bodyFatPercentage = "body_fat_percentage"
        case leanBodyMass = "lean_body_mass"
        case respiratoryRate = "respiratory_rate"
        case spo2
    }
}

// MARK: - Sleep Stages

struct SleepStages: Codable, Sendable {
    let awake: Double?                      // seconds
    let rem: Double?                        // seconds
    let core: Double?                       // seconds (light sleep)
    let deep: Double?                       // seconds
}

// MARK: - Bulk Payload

// Marked `nonisolated` so its Codable conformance can be used from the
// WorkoutAPIClient actor (types default to @MainActor in this project).
nonisolated struct HealthMetricsBulkPayload: Codable, Sendable {
    let metrics: [DailyHealthMetrics]
}

// MARK: - Sync Response

struct HealthMetricsSyncResponse: Codable, Sendable {
    let upserted: Int
}
