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
    /// Recent runs still on the pair they got automatically, by workout id.
    /// The value is that pair (nil = none). Empty unless there is more than
    /// one pair to choose between.
    private(set) var uncheckedRuns: [UUID: UUID?] = [:]

    /// How far back a run is still worth asking about.
    private static let checkWindow: TimeInterval = 14 * 24 * 60 * 60

    private let apiClient: WorkoutAPIClient

    init(apiClient: WorkoutAPIClient) {
        self.apiClient = apiClient
    }

    var inUse: [Shoe] { shoes.filter { !$0.isRetired } }
    var retired: [Shoe] { shoes.filter(\.isRetired) }

    /// Whether to ask the athlete which pair they wore on this run.
    func needsCheck(workoutId: UUID) -> Bool {
        uncheckedRuns[workoutId] != nil
    }

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
            return
        }
        await loadUncheckedRuns()
    }

    /// With one pair in rotation the automatic choice can't be wrong, so
    /// nothing is asked. A failure keeps what is already flagged.
    private func loadUncheckedRuns() async {
        guard inUse.count > 1 else {
            uncheckedRuns = [:]
            return
        }
        do {
            let runs = try await apiClient.fetchRunShoeStates(since: Date().addingTimeInterval(-Self.checkWindow))
            uncheckedRuns = Dictionary(
                runs.filter { $0.isConfirmed == false }.map { ($0.id, $0.shoeId) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            AppLog.sync.error("Failed to load unchecked runs: \(String(describing: error), privacy: .public)")
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
    /// Setting the pair the workout already has is how it is confirmed.
    func assign(shoeId: UUID?, toWorkout workoutId: UUID) async throws {
        try await apiClient.setWorkoutShoe(workoutId: workoutId, shoeId: shoeId)
        uncheckedRuns[workoutId] = nil
        await load()
    }

    /// The signed-in account changed: the list belongs to the previous one.
    func reset() {
        shoes = []
        uncheckedRuns = [:]
        loadState = .idle
    }
}
