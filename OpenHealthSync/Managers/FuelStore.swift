//
//  FuelStore.swift
//  OpenHealthSync
//
//  The athlete's saved drinks, gels and other fuel, as the server has them.
//  Every change is followed by a fresh read, like the shoes.
//

import Foundation
import os

@MainActor
@Observable
final class FuelStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var products: [FuelProduct] = []
    private(set) var loadState: LoadState = .idle

    private let apiClient: WorkoutAPIClient

    init(apiClient: WorkoutAPIClient) {
        self.apiClient = apiClient
    }

    var drinks: [FuelProduct] { products.filter { $0.kind == .drink } }
    var items: [FuelProduct] { products.filter { $0.kind != .drink } }

    /// Refreshes the list. A failure keeps whatever is already shown.
    func load() async {
        if loadState != .loaded { loadState = .loading }
        do {
            products = try await apiClient.fetchFuelProducts()
            loadState = .loaded
        } catch {
            AppLog.sync.error("Failed to load fuel products: \(String(describing: error), privacy: .public)")
            if products.isEmpty { loadState = .failed }
        }
    }

    /// For screens that only need the list to pick from.
    func loadIfNeeded() async {
        if loadState != .loaded { await load() }
    }

    func add(_ draft: FuelProductDraft) async throws {
        _ = try await apiClient.createFuelProduct(draft)
        await load()
    }

    func update(_ product: FuelProduct, with draft: FuelProductDraft) async throws {
        _ = try await apiClient.updateFuelProduct(id: product.id, draft: draft)
        await load()
    }

    func delete(_ product: FuelProduct) async throws {
        try await apiClient.deleteFuelProduct(id: product.id)
        await load()
    }

    // MARK: - A workout's log and a session's plan

    /// What was taken on a workout and what was planned for it; nil when the
    /// workout isn't on the server (not synced yet), the server predates
    /// fuelling, or it can't be reached.
    func workoutFuel(workoutId: UUID) async -> WorkoutFuel? {
        (try? await loadWorkoutFuel(workoutId: workoutId)) ?? nil
    }

    /// The same, for a caller that has to tell the two apart: nil when the
    /// workout isn't on the server or the server predates fuelling, a throw
    /// when the server can't be reached.
    func loadWorkoutFuel(workoutId: UUID) async throws -> WorkoutFuel? {
        try await apiClient.fetchWorkoutFuel(workoutId: workoutId)
    }

    func setWorkoutFuel(workoutId: UUID, entries: [FuelEntryDraft]) async throws -> WorkoutFuel {
        try await apiClient.setWorkoutFuel(workoutId: workoutId, entries: entries)
    }

    /// The plan on a planned session; nil as above.
    func sessionFuel(sessionId: UUID) async -> SessionFuel? {
        (try? await apiClient.fetchSessionFuel(sessionId: sessionId)) ?? nil
    }

    func setSessionFuel(sessionId: UUID, entries: [FuelEntryDraft]) async throws -> SessionFuel {
        try await apiClient.setSessionFuel(sessionId: sessionId, entries: entries)
    }

    /// The signed-in account changed: the list belongs to the previous one.
    func reset() {
        products = []
        loadState = .idle
    }
}
