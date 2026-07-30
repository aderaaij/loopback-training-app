//
//  NutritionModels.swift
//  OpenHealthSync
//
//  Wire models for the nutrition resource: POST /api/nutrition (bulk day
//  upsert) and GET /api/nutrition (day rows for the Trends segment).
//  snake_case like DailyHealthMetrics — the server also accepts camelCase
//  aliases, but the existing metrics model sets the house style.
//
//  Marked `nonisolated` because the project defaults types to @MainActor
//  (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor); without this their Codable
//  conformances couldn't be used from the WorkoutAPIClient actor.
//

import Foundation

// MARK: - Daily Nutrition

/// One local calendar day of dietary intake.
///
/// Every field but `date` is optional, and a null never overwrites a stored
/// value server-side — so shipping a subset now and widening it later needs no
/// migration and no coordinated release.
///
/// Days with no dietary samples at all are never sent: the server reads an
/// absent row as "not tracked", and posting an explicit zero would assert the
/// athlete ate nothing.
///
/// Deliberately absent: any intake-minus-expenditure "net" figure. The server
/// reports intake and training energy separately on purpose — a balance needs
/// a BMR the app doesn't have, and self-reported intake runs 10–30% low, so
/// the arithmetic would look authoritative while being wrong.
nonisolated struct DailyNutrition: Codable, Sendable {
    let date: String                        // "2026-07-29" (local day, no time)
    let energyKcal: Double?                 // kcal
    let carbsG: Double?                     // g
    let proteinG: Double?                   // g
    let fatG: Double?                       // g
    let saturatedFatG: Double?              // g
    let fiberG: Double?                     // g
    let sugarG: Double?                     // g
    let sodiumMg: Double?                   // mg
    let potassiumMg: Double?                // mg
    let cholesterolMg: Double?              // mg
    let waterMl: Double?                    // mL
    let caffeineMg: Double?                 // mg
    /// Open `name → value` dictionary for anything outside the columns above;
    /// the server stores whatever keys arrive, no migration needed. Keep the
    /// key set stable across releases — a small consistent set reads far
    /// better than a wide inconsistent one.
    let micros: [String: Double]?
    /// How many entries were logged that day, and which apps wrote them.
    /// Logging adherence is itself a signal when reading a diet trend, and the
    /// source list identifies the writer when two apps disagree.
    let entryCount: Int?
    let sources: [String]?
    /// True while the day is still being eaten. Keeps the day out of every
    /// server-side average (dashboard, /summary, MCP) until a later sync
    /// re-sends it complete with `partial: false`.
    let partial: Bool?

    enum CodingKeys: String, CodingKey {
        case date
        case energyKcal = "energy_kcal"
        case carbsG = "carbs_g"
        case proteinG = "protein_g"
        case fatG = "fat_g"
        case saturatedFatG = "saturated_fat_g"
        case fiberG = "fiber_g"
        case sugarG = "sugar_g"
        case sodiumMg = "sodium_mg"
        case potassiumMg = "potassium_mg"
        case cholesterolMg = "cholesterol_mg"
        case waterMl = "water_ml"
        case caffeineMg = "caffeine_mg"
        case micros
        case entryCount = "entry_count"
        case sources
        case partial
    }

    /// The day as a local `Date`, parsed from "yyyy-MM-dd". A fresh
    /// fixed-locale formatter per call keeps the type Sendable-safe, mirroring
    /// `ServerWorkoutSummaryRow.periodStart`.
    var day: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }

    var isPartial: Bool { partial ?? false }
}

// MARK: - Bulk Payload

nonisolated struct NutritionBulkPayload: Codable, Sendable {
    let days: [DailyNutrition]
}

// MARK: - Read Response

/// Decodes `GET /api/nutrition` whether the server answers with a bare array
/// (the house style for `/api/plans` and `/api/workouts/summary`) or wraps the
/// rows under `days` like the upload payload does. Individual rows decode
/// failably so one malformed day can't blank the whole screen.
nonisolated struct NutritionDaysResponse: Decodable, Sendable {
    let days: [DailyNutrition]

    init(from decoder: Decoder) throws {
        if let bare = try? [FailableDecodable<DailyNutrition>](from: decoder) {
            days = bare.compactMap(\.value)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container
            .decode([FailableDecodable<DailyNutrition>].self, forKey: .days)
            .compactMap(\.value)
    }

    enum CodingKeys: String, CodingKey {
        case days
    }
}
