//
//  FuelModels.swift
//  OpenHealthSync
//
//  Fuelling (server 0.1.27+): what is drunk and eaten on a workout, and what
//  is planned for a session. Entered by hand, unlike the nutrition sync,
//  which is daily totals read from Health. The endpoints are camelCase and
//  speak ml, g, mg and meters.
//

import Foundation

/// A drink is logged as one total for the workout; a gel or anything else as
/// single items, each at a point in it.
nonisolated enum FuelKind: String, CaseIterable, Identifiable, Sendable {
    case drink, gel, other

    var id: String { rawValue }

    /// A kind this build doesn't know reads as "other".
    init(wire: String) {
        self = FuelKind(rawValue: wire) ?? .other
    }

    var label: String {
        switch self {
        case .drink: "Drink"
        case .gel: "Gel"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .drink: "waterbottle.fill"
        case .gel: "bolt.fill"
        case .other: "takeoutbag.and.cup.and.straw.fill"
        }
    }
}

/// Something saved once so logging it is a pick: a gel, a drink mix.
nonisolated struct FuelProduct: Decodable, Sendable, Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let kind: FuelKind
    /// A drink's serving in ml, which the two figures below are for.
    let volumeMl: Double?
    /// Per serving of a drink, per piece of anything else; nil = not stated.
    let carbsG: Double?
    let caffeineMg: Double?

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, volumeMl, carbsG, caffeineMg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = FuelKind(wire: try container.decode(String.self, forKey: .kind))
        volumeMl = try container.decodeIfPresent(Double.self, forKey: .volumeMl)
        carbsG = try container.decodeIfPresent(Double.self, forKey: .carbsG)
        caffeineMg = try container.decodeIfPresent(Double.self, forKey: .caffeineMg)
    }
}

/// What the athlete can set on a product.
nonisolated struct FuelProductDraft: Sendable, Equatable {
    var name: String
    var kind: FuelKind
    var volumeMl: Double?
    var carbsG: Double?
    var caffeineMg: Double?
}

/// One thing drunk or eaten, or planned to be. The name and figures are the
/// entry's own: the server copies them from the product when it is made.
nonisolated struct FuelEntry: Decodable, Sendable, Identifiable, Equatable {
    let id: UUID
    let productId: UUID?
    let name: String
    let kind: FuelKind
    /// For a drink: the total over the workout.
    let volumeMl: Double?
    /// In the entry as a whole.
    let carbsG: Double?
    let caffeineMg: Double?
    /// Meters into the workout; nil for a drink or when not placed.
    let atDistance: Double?

    private enum CodingKeys: String, CodingKey {
        case id, productId, name, kind, volumeMl, carbsG, caffeineMg, atDistance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        productId = try container.decodeIfPresent(UUID.self, forKey: .productId)
        name = try container.decode(String.self, forKey: .name)
        kind = FuelKind(wire: try container.decode(String.self, forKey: .kind))
        volumeMl = try container.decodeIfPresent(Double.self, forKey: .volumeMl)
        carbsG = try container.decodeIfPresent(Double.self, forKey: .carbsG)
        caffeineMg = try container.decodeIfPresent(Double.self, forKey: .caffeineMg)
        atDistance = try container.decodeIfPresent(Double.self, forKey: .atDistance)
    }

    /// The same entry as something to send, figures spelled out, so that
    /// sending a list back never has the server re-read them from a product
    /// that has changed since.
    var draft: FuelEntryDraft {
        FuelEntryDraft(
            productId: productId, name: name, kind: kind,
            volumeMl: volumeMl, carbsG: carbsG, caffeineMg: caffeineMg, atDistance: atDistance
        )
    }
}

/// An entry to send. Every figure goes out, nil as null, which the server
/// reads as "none" rather than "take it from the product".
nonisolated struct FuelEntryDraft: Sendable, Equatable {
    var productId: UUID?
    var name: String
    var kind: FuelKind
    var volumeMl: Double?
    var carbsG: Double?
    var caffeineMg: Double?
    var atDistance: Double?

    /// A product as an entry: one serving of a drink, one piece of the rest.
    init(product: FuelProduct) {
        self.init(
            productId: product.id, name: product.name, kind: product.kind,
            volumeMl: product.kind == .drink ? product.volumeMl : nil,
            carbsG: product.carbsG, caffeineMg: product.caffeineMg, atDistance: nil
        )
    }

    init(
        productId: UUID? = nil, name: String, kind: FuelKind,
        volumeMl: Double? = nil, carbsG: Double? = nil, caffeineMg: Double? = nil, atDistance: Double? = nil
    ) {
        self.productId = productId
        self.name = name
        self.kind = kind
        self.volumeMl = volumeMl
        self.carbsG = carbsG
        self.caffeineMg = caffeineMg
        self.atDistance = atDistance
    }

    var json: [String: Any] {
        func value(_ number: Double?) -> Any { number ?? NSNull() }
        return [
            "productId": productId?.uuidString ?? NSNull(),
            "name": name,
            "kind": kind.rawValue,
            "volumeMl": value(volumeMl),
            "carbsG": value(carbsG),
            "caffeineMg": value(caffeineMg),
            "atDistance": value(atDistance),
        ]
    }
}

/// Totals over a list of entries. An entry without a figure counts as zero.
nonisolated struct FuelSummary: Decodable, Sendable, Equatable {
    let volumeMl: Double
    let carbsG: Double
    let caffeineMg: Double
    /// Per hour of the workout; nil for a plan on its own and for a workout
    /// too short for a rate to mean much.
    let carbsPerHourG: Double?
    let fluidPerHourMl: Double?
}

/// What was taken on a workout, next to what was planned for it.
nonisolated struct WorkoutFuel: Decodable, Sendable, Equatable {
    let entries: [FuelEntry]
    let summary: FuelSummary
    /// The plan on the session this workout counts for; empty without one.
    let planned: [FuelEntry]
    let plannedSummary: FuelSummary?
}

/// The fuelling plan on a planned session.
nonisolated struct SessionFuel: Decodable, Sendable, Equatable {
    let entries: [FuelEntry]
    let summary: FuelSummary
}
