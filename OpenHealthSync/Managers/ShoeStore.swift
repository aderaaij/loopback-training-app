//
//  ShoeStore.swift
//  OpenHealthSync
//
//  The athlete's pairs of shoes, as the server has them. The server owns the
//  list and the mileage, so every change is followed by a fresh read.
//

import Foundation
import os

@MainActor
@Observable
final class ShoeStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var shoes: [Shoe] = []
    private(set) var loadState: LoadState = .idle

    private let apiClient: WorkoutAPIClient

    init(apiClient: WorkoutAPIClient) {
        self.apiClient = apiClient
    }

    var inUse: [Shoe] { shoes.filter { !$0.isRetired } }
    var retired: [Shoe] { shoes.filter(\.isRetired) }

    func shoe(id: UUID?) -> Shoe? {
        guard let id else { return nil }
        return shoes.first { $0.id == id }
    }

    /// Refreshes the list. A failure keeps whatever is already shown.
    func load() async {
        if loadState != .loaded { loadState = .loading }
        do {
            shoes = try await apiClient.fetchShoes()
            loadState = .loaded
        } catch {
            AppLog.sync.error("Failed to load shoes: \(String(describing: error), privacy: .public)")
            if shoes.isEmpty { loadState = .failed }
        }
    }

    func add(_ draft: ShoeDraft) async throws {
        _ = try await apiClient.createShoe(draft)
        await load()
    }

    func update(_ shoe: Shoe, with draft: ShoeDraft) async throws {
        _ = try await apiClient.updateShoe(id: shoe.id, draft: draft)
        await load()
    }

    func setRetired(_ shoe: Shoe, _ retired: Bool) async throws {
        _ = try await apiClient.updateShoe(id: shoe.id, retired: retired)
        await load()
    }

    func delete(_ shoe: Shoe) async throws {
        try await apiClient.deleteShoe(id: shoe.id)
        await load()
    }

    /// The pair on a workout; nil when the workout isn't on the server (not
    /// synced yet) or the server predates shoe tracking.
    func workoutShoe(workoutId: UUID) async -> WorkoutShoe? {
        guard let found = try? await apiClient.fetchWorkoutShoe(workoutId: workoutId),
              found.isSupported else { return nil }
        return found
    }

    /// Puts a pair on a workout (nil takes it off), then refreshes mileage.
    func assign(shoeId: UUID?, toWorkout workoutId: UUID) async throws {
        try await apiClient.setWorkoutShoe(workoutId: workoutId, shoeId: shoeId)
        await load()
    }

    /// The signed-in account changed: the list belongs to the previous one.
    func reset() {
        shoes = []
        loadState = .idle
    }
}
