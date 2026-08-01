//
//  DataDomains.swift
//  OpenHealthSync
//
//  What the athlete has agreed to share, expressed as domains rather than as
//  individual HealthKit types.
//
//  This exists because iOS cannot answer the question we actually need
//  answered. HealthKit read authorization is deliberately unreadable —
//  `authorizationStatus(for:)` reflects *share* access only, and
//  `getRequestStatusForAuthorization` says whether we'd show a sheet, i.e.
//  whether we've asked, never whether the athlete said yes. So an athlete who
//  denied sleep is indistinguishable from one who simply doesn't wear a watch
//  at night, and neither is distinguishable from consent.
//
//  Three layers keep those apart:
//
//    Intent   — this file. Our own state, set in onboarding, edited in
//               Settings. Gates screens, sync paths, and the coach's tools.
//    Grant    — the OS permission. Requested for the intended domains only,
//               and never treated as queryable state.
//    Evidence — whether a domain has actually produced samples recently
//               (`HealthMetricsSyncer.lastSampleDates`). The only honest signal
//               that a domain is working, and the one that drives "check your
//               Health settings" affordances.
//
//  The rule: intent gates surfaces, evidence gates content. Intent off means
//  the surface doesn't exist and we never nag. Intent on with no evidence
//  means we show the fixup path.
//

import Foundation
import HealthKit
import SwiftUI

// MARK: - Domains

/// A set of health-data domains the athlete has agreed to share.
///
/// Domains — not individual `HKObjectType`s — are the unit of consent because
/// they're the unit everything else already groups by: read-authorization
/// batches, sync paths, server tables, Trends sections, and MCP tools.
///
/// `nonisolated` because the `HealthMetricsSyncer` actor reads it constantly
/// and types default to `@MainActor` in this module. Only the presentation
/// extension below stays on the main actor, since it reaches into `LB`.
nonisolated struct DataDomains: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    /// Workouts, routes, in-workout heart rate, effort. Not optional: without
    /// it there is no training history, which is the whole app.
    static let training  = DataDomains(rawValue: 1 << 0)
    /// Sleep, resting heart rate, HRV, respiratory rate, blood oxygen.
    static let recovery  = DataDomains(rawValue: 1 << 1)
    /// Weight, body composition, VO₂ max.
    static let body      = DataDomains(rawValue: 1 << 2)
    /// Steps, active and basal energy.
    static let activity  = DataDomains(rawValue: 1 << 3)
    /// Logged food and drink.
    static let nutrition = DataDomains(rawValue: 1 << 4)

    /// The floor. Every stored value is unioned with this — a set without
    /// training would leave the app unable to do the one thing it's for.
    static let required: DataDomains = [.training]
    static let all: DataDomains = [.training, .recovery, .body, .activity, .nutrition]

    /// Display order, and the iteration order for everything below.
    static let ordered: [DataDomains] = [.training, .recovery, .body, .activity, .nutrition]

    /// The individual domains this set contains, in display order. Lets the
    /// per-domain metadata below stay defined on single flags.
    var elements: [DataDomains] { Self.ordered.filter { contains($0) } }

    /// The domains an athlete can actually turn off, in display order.
    static var optional: [DataDomains] { ordered.filter { $0 != .training } }

    var isRequired: Bool { self == .training }
}

// MARK: - Presentation

@MainActor
extension DataDomains {
    var title: String {
        switch self {
        case .training:  return "Training"
        case .recovery:  return "Recovery"
        case .body:      return "Body"
        case .activity:  return "Daily activity"
        case .nutrition: return "Nutrition"
        default:         return "Health data"
        }
    }

    /// The concrete metrics behind the domain name. Athletes consent to
    /// specifics, not to categories, so every surface that offers a toggle
    /// shows this line next to it.
    var subtitle: String {
        switch self {
        case .training:  return "Runs, routes, heart rate and effort"
        case .recovery:  return "Sleep, resting heart rate, HRV, breathing and blood oxygen"
        case .body:      return "Weight, body composition and VO₂ max"
        case .activity:  return "Steps and energy burned across the day"
        case .nutrition: return "Food and drink you log"
        default:         return ""
        }
    }

    /// Why the coach wants it — shown in onboarding, where the athlete is
    /// deciding rather than reviewing.
    var rationale: String {
        switch self {
        case .training:  return "How your training is actually going."
        case .recovery:  return "Whether you're absorbing the work or digging a hole."
        case .body:      return "Long-range changes in fitness and body composition."
        case .activity:  return "What you do on the other 23 hours of the day."
        case .nutrition: return "Whether you're fuelling the training you're doing."
        default:         return ""
        }
    }

    var symbol: String {
        switch self {
        case .training:  return "figure.run"
        case .recovery:  return "moon.zzz"
        case .body:      return "figure.stand"
        case .activity:  return "flame"
        case .nutrition: return "fork.knife"
        default:         return "heart"
        }
    }

    var tint: Color {
        switch self {
        case .training:  return LB.accent
        case .recovery:  return LB.violet
        case .body:      return LB.blue
        case .activity:  return LB.amber
        case .nutrition: return LB.green
        default:         return LB.accent
        }
    }
}

// MARK: - Wire format

nonisolated extension DataDomains {
    /// Stable snake_case identifier. The server stores these on the user record
    /// and the MCP layer filters its advertised tool list against them, so the
    /// strings are API surface — renaming one silently revokes a domain.
    var wireValue: String {
        switch self {
        case .training:  return "training"
        case .recovery:  return "recovery"
        case .body:      return "body"
        case .activity:  return "activity"
        case .nutrition: return "nutrition"
        default:         return "unknown"
        }
    }

    var wireValues: [String] { elements.map(\.wireValue) }
}

/// Body of `PUT /api/me/data-consent`. The server records it on the user and
/// the MCP layer advertises only the tools whose domain appears here.
nonisolated struct DataConsentPayload: Encodable, Sendable {
    let domains: [String]

    init(_ domains: DataDomains) {
        self.domains = domains.wireValues
    }
}

// MARK: - HealthKit types

nonisolated extension DataDomains {
    /// Read types for a single domain. Requesting per domain — rather than the
    /// old single union of every type — keeps the system sheet short at
    /// onboarding and stops us holding authorization we've no intention of
    /// using.
    private var ownReadTypes: Set<HKObjectType> {
        switch self {
        case .training:
            return [
                HKObjectType.workoutType(),
                HKSeriesType.workoutRoute(),
                HKQuantityType(.heartRate),
                // Workout effort (RPE 1–10), consumed by WorkoutExtractor.
                HKQuantityType(.workoutEffortScore),
                HKQuantityType(.estimatedWorkoutEffortScore),
                // Read once during onboarding to seed a single age observation
                // for the coach. Rides with training because training is the
                // domain that's always granted; it's a characteristic, so there
                // is no sample stream behind it.
                HKCharacteristicType(.dateOfBirth),
            ]
        case .recovery:
            return [
                HKCategoryType(.sleepAnalysis),
                HKQuantityType(.restingHeartRate),
                HKQuantityType(.heartRateVariabilitySDNN),
                HKQuantityType(.respiratoryRate),
                HKQuantityType(.oxygenSaturation),
            ]
        case .body:
            return [
                HKQuantityType(.bodyMass),
                HKQuantityType(.bodyFatPercentage),
                HKQuantityType(.leanBodyMass),
                HKQuantityType(.vo2Max),
            ]
        case .activity:
            return [
                HKQuantityType(.stepCount),
                HKQuantityType(.activeEnergyBurned),
                HKQuantityType(.basalEnergyBurned),
            ]
        case .nutrition:
            return Self.dietaryReadTypes
        default:
            return []
        }
    }

    /// Every read type across the domains in this set.
    var healthKitReadTypes: Set<HKObjectType> {
        elements.reduce(into: Set<HKObjectType>()) { $0.formUnion($1.ownReadTypes) }
    }

    /// The type whose newest sample stands in for the whole domain when
    /// measuring evidence. Each is the one an athlete sharing that domain would
    /// certainly have: no sample here means the domain isn't flowing, whatever
    /// the athlete intended.
    var sentinelType: HKSampleType? {
        switch self {
        case .training:  return HKObjectType.workoutType()
        case .recovery:  return HKCategoryType(.sleepAnalysis)
        case .body:      return HKQuantityType(.bodyMass)
        case .activity:  return HKQuantityType(.stepCount)
        case .nutrition: return HKQuantityType(.dietaryEnergyConsumed)
        default:         return nil
        }
    }

    /// Types worth a background-delivery observer, with how often iOS should
    /// wake us. Registering these per domain means we stop being woken for data
    /// we would only discard.
    var observedTypes: [(type: HKSampleType, frequency: HKUpdateFrequency)] {
        switch self {
        case .training:
            return [(HKObjectType.workoutType(), .immediate)]
        case .recovery:
            return [
                (HKCategoryType(.sleepAnalysis), .hourly),
                (HKQuantityType(.restingHeartRate), .hourly),
                (HKQuantityType(.heartRateVariabilitySDNN), .hourly),
            ]
        case .body:
            return [(HKQuantityType(.bodyMass), .immediate)]
        case .activity:
            return [
                (HKQuantityType(.stepCount), .hourly),
                (HKQuantityType(.activeEnergyBurned), .hourly),
            ]
        case .nutrition:
            // One dietary observer covers all of nutrition: food-logging apps
            // write every nutrient of a meal together, so an energy sample
            // landing means the rest did too, and syncMetrics() re-reads
            // everything anyway. `.hourly` on purpose — a logged lunch isn't
            // time-critical, and `.immediate` on a type that fires several
            // times per meal is wasted wakeups.
            return [(HKQuantityType(.dietaryEnergyConsumed), .hourly)]
        default:
            return []
        }
    }

    /// Dietary types backing nutrition sync, split out only for readability.
    static let dietaryReadTypes: Set<HKObjectType> = [
        HKQuantityType(.dietaryEnergyConsumed),
        HKQuantityType(.dietaryCarbohydrates),
        HKQuantityType(.dietaryProtein),
        HKQuantityType(.dietaryFatTotal),
        HKQuantityType(.dietaryFatSaturated),
        HKQuantityType(.dietaryFiber),
        HKQuantityType(.dietarySugar),
        HKQuantityType(.dietarySodium),
        HKQuantityType(.dietaryPotassium),
        HKQuantityType(.dietaryCholesterol),
        HKQuantityType(.dietaryWater),
        HKQuantityType(.dietaryCaffeine),
        // Micros. Cheap to read and free to store (they ride in the payload's
        // open `micros` dictionary), but the key set must stay stable.
        HKQuantityType(.dietaryIron),
        HKQuantityType(.dietaryCalcium),
        HKQuantityType(.dietaryMagnesium),
        HKQuantityType(.dietaryVitaminC),
    ]
}

// MARK: - Storage

/// Reads and writes the athlete's intent. Plain `UserDefaults` because both the
/// `HealthMetricsSyncer` actor and SwiftUI views need it, and `@AppStorage`
/// only serves the latter — views bind to `DataDomains.appStorageKey` and see
/// the same bytes.
nonisolated enum DataConsent {
    /// Key backing both this store and the views' `@AppStorage`.
    static let appStorageKey = "dataDomains"
    private static let legacyEnabledKey = "healthMetricsSyncEnabled"
    private static let onboardingKey = "hasCompletedOnboarding"

    /// What the athlete has agreed to share right now.
    static var current: DataDomains {
        guard let raw = UserDefaults.standard.object(forKey: appStorageKey) as? Int else {
            // `migrateIfNeeded()` runs at launch, so this is only reachable
            // before it does. The floor is the safe answer: it syncs nothing
            // the athlete hasn't been asked about.
            return .required
        }
        return DataDomains(rawValue: raw).union(.required)
    }

    static func set(_ domains: DataDomains) {
        UserDefaults.standard.set(domains.union(.required).rawValue, forKey: appStorageKey)
    }

    /// Establishes intent for installs that predate it. Call once at launch,
    /// before anything reads `current`.
    ///
    /// Existing athletes had a single "sync health data" switch covering every
    /// type at once. It defaulted to on and only went off if they turned it
    /// off, so on-or-absent has to mean everything — mapping it to anything
    /// narrower would revoke, on their behalf, consent they'd already given.
    ///
    /// A fresh install has the same absent key but hasn't been asked anything
    /// yet, so it starts at the floor and onboarding fills in the rest.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: appStorageKey) == nil else { return }

        guard defaults.bool(forKey: onboardingKey) else {
            set(.required)
            return
        }

        let wasSyncing = defaults.object(forKey: legacyEnabledKey) as? Bool ?? true
        set(wasSyncing ? .all : .required)
    }
}
