//
//  HealthMetricsModels.swift
//  OpenHealthSync
//
//  Created by Claude on 04/04/2026.
//

import Foundation

// MARK: - Daily Health Metrics

// Sleep is deliberately absent here: it ships as raw samples (below), never
// as app-computed daily totals — the server owns night attribution and stage
// merging, and ignores legacy sleep fields once it holds samples.
struct DailyHealthMetrics: Codable, Sendable {
    let date: String                        // "2026-04-04" (ISO date, no time)
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

// MARK: - Raw Sleep Samples

// Marked `nonisolated` like the bulk payload below, for the same reason.
nonisolated struct SleepSamplePayload: Codable, Sendable {
    let start: Date
    let end: Date
    let stage: String                       // rem | core | deep | awake | unspecified | in_bed
    let source: String                      // HealthKit writer's bundle identifier
}

nonisolated struct SleepSamplesUploadPayload: Codable, Sendable {
    let timezone: String                    // IANA identifier, e.g. Europe/Amsterdam
    let samples: [SleepSamplePayload]
}

nonisolated struct SleepSamplesUploadResponse: Codable, Sendable {
    let stored: Int
    let daysUpdated: [String]               // "yyyy-MM-dd" days whose rollups re-derived

    enum CodingKeys: String, CodingKey {
        case stored
        case daysUpdated = "days_updated"
    }
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
