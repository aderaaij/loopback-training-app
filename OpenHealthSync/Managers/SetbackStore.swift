//
//  SetbackStore.swift
//  OpenHealthSync
//
//  The athlete's illnesses and injuries, as the server has them. The server
//  owns the list, so every change is followed by a fresh read.
//

import Foundation
import os

@MainActor
@Observable
final class SetbackStore {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    private(set) var setbacks: [Setback] = []
    private(set) var loadState: LoadState = .idle

    private let apiClient: WorkoutAPIClient

    init(apiClient: WorkoutAPIClient) {
        self.apiClient = apiClient
    }

    /// Still going on.
    var active: [Setback] { setbacks.filter(\.isActive) }
    var past: [Setback] { setbacks.filter { !$0.isActive } }

    /// The open setback a new one of this kind would duplicate. The server
    /// allows one open illness, and one open injury per body part.
    func openSetback(kind: SetbackKind, bodyPart: String? = nil) -> Setback? {
        active.first { setback in
            guard setback.kind == kind else { return false }
            if kind == .illness { return true }
            return (setback.bodyPart ?? "").lowercased() == (bodyPart ?? "").lowercased()
        }
    }

    /// A setback of this kind, open or finished, that already includes the day.
    func setback(kind: SetbackKind, covering day: SetbackDay) -> Setback? {
        setbacks.first { setback in
            setback.kind == kind && setback.start <= day && (setback.end.map { day <= $0 } ?? true)
        }
    }

    /// Refreshes the list. A failure keeps whatever is already shown; a
    /// server that predates setbacks simply never loads.
    func load() async {
        if loadState != .loaded { loadState = .loading }
        do {
            setbacks = try await apiClient.fetchSetbacks()
            loadState = .loaded
        } catch {
            AppLog.sync.error("Failed to load setbacks: \(String(describing: error), privacy: .public)")
            if loadState != .loaded { loadState = .failed }
        }
    }

    func add(_ draft: SetbackDraft) async throws {
        _ = try await apiClient.createSetback(draft, id: UUID())
        await load()
    }

    func update(_ setback: Setback, with draft: SetbackDraft) async throws {
        _ = try await apiClient.updateSetback(id: setback.id, draft: draft)
        await load()
    }

    /// Closes a setback on its last affected day.
    func close(_ setback: Setback, lastDay: SetbackDay) async throws {
        _ = try await apiClient.setSetbackEnd(id: setback.id, end: max(lastDay, setback.start))
        await load()
    }

    func delete(_ setback: Setback) async throws {
        try await apiClient.deleteSetback(id: setback.id)
        await load()
    }

    /// Records how the athlete feels today.
    func checkIn(_ setback: Setback, status: SetbackStatus) async throws {
        let updated = try await apiClient.putSetbackCheckin(id: setback.id, day: .today, status: status)
        if let index = setbacks.firstIndex(where: { $0.id == setback.id }) {
            setbacks[index] = updated
        }
    }

    /// Called when a run is missed, moved or skipped because the athlete is
    /// sick or injured. Nothing happens when a setback of the kind already
    /// includes that day. Otherwise an open one has its start moved back to
    /// the day, and failing that a new one opens there. Best effort; the
    /// check-in itself already carries the reason.
    func noteSetback(kind: SetbackKind, on runDate: Date, note: String?) async {
        if loadState != .loaded { await load() }
        guard loadState == .loaded else { return }

        let day = min(SetbackDay(runDate), .today)
        guard setback(kind: kind, covering: day) == nil else { return }
        do {
            if let open = active.first(where: { $0.kind == kind }) {
                guard day < open.start else { return }
                let draft = SetbackDraft(
                    kind: open.kind, severity: open.severity, start: day, end: nil,
                    bodyPart: open.bodyPart, note: open.note
                )
                try await update(open, with: draft)
            } else {
                let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
                try await add(SetbackDraft(
                    kind: kind, severity: .moderate, start: day, end: nil,
                    bodyPart: nil, note: (trimmed?.isEmpty ?? true) ? nil : trimmed
                ))
            }
        } catch {
            AppLog.sync.error("Failed to note a setback from a check-in: \(String(describing: error), privacy: .public)")
        }
    }

    /// The signed-in account changed: the list belongs to the previous one.
    func reset() {
        setbacks = []
        loadState = .idle
    }
}
