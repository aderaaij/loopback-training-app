//
//  ShoeModels.swift
//  OpenHealthSync
//
//  Shoe tracking (server 0.1.19+): pairs of shoes and the distance on each.
//  The /api/shoes endpoints are camelCase and speak meters.
//

import Foundation

nonisolated struct Shoe: Decodable, Sendable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    /// Meters already on the pair when it was added.
    let startDistance: Double
    /// Meters the pair is expected to last; nil = no target.
    let targetDistance: Double?
    /// New runs are assigned to this pair as they sync.
    let isDefault: Bool
    /// Kept as text: only its presence matters here, and the server's
    /// fractional-second timestamps don't parse with the shared decoder.
    let retiredAt: String?
    /// Starting distance plus every assigned workout, in meters.
    let distance: Double
    let workoutCount: Int

    var isRetired: Bool { retiredAt != nil }

    /// Share of the target used; nil without a target. Can exceed 1.
    var wornFraction: Double? {
        guard let targetDistance, targetDistance > 0 else { return nil }
        return distance / targetDistance
    }

    enum Wear {
        case fine
        case wearingOut
        case pastTarget
    }

    /// From 90% of the target on, the pair is flagged for replacement.
    var wear: Wear {
        guard let fraction = wornFraction else { return .fine }
        if fraction >= 1 { return .pastTarget }
        if fraction >= 0.9 { return .wearingOut }
        return .fine
    }
}

/// What the athlete can set on a pair, in meters.
nonisolated struct ShoeDraft: Sendable, Equatable {
    var name: String
    var startDistance: Double
    var targetDistance: Double?
    var isDefault: Bool
}

/// A recent run as the workout list returns it, reduced to its pair and
/// whether anyone has checked that pair (server 0.1.21+).
nonisolated struct RunShoeState: Decodable, Sendable {
    let id: UUID
    let shoeId: UUID?
    /// False while the pair is still the one assigned automatically; nil
    /// from a server that doesn't track it.
    let isConfirmed: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case shoeId = "shoe_id"
        case isConfirmed = "shoe_confirmed"
    }
}

/// The pair on one workout, read from the workout itself.
nonisolated struct WorkoutShoe: Decodable, Sendable {
    let shoeId: UUID?
    /// False when the server predates shoe tracking and sent no such field.
    let isSupported: Bool

    private enum CodingKeys: String, CodingKey {
        case shoeId = "shoe_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSupported = container.contains(.shoeId)
        shoeId = try container.decodeIfPresent(UUID.self, forKey: .shoeId)
    }
}
