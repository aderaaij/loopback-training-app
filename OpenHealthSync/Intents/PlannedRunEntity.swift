//
//  PlannedRunEntity.swift
//  OpenHealthSync
//
//  A planned run as Siri and Shortcuts see it: one of the sessions still to
//  do, today's included. Its id is the session's own, the same one the watch,
//  the server's queue and the plan know it by.
//

import AppIntents
import Foundation
import WorkoutKit

struct PlannedRunEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Planned Run")
    static let defaultQuery = PlannedRunQuery()

    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Date")
    var date: Date

    /// Nil when the session isn't written as distances throughout.
    @Property(title: "Distance")
    var distance: Measurement<UnitLength>?

    var displayRepresentation: DisplayRepresentation {
        let when = IntentPhrasing.when(date)
        return DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(when.prefix(1).uppercased() + when.dropFirst())"
        )
    }

    init(id: UUID, name: String, date: Date, distanceMeters: Double?) {
        self.id = id
        self.name = name
        self.date = date
        self.distance = distanceMeters.map { Measurement(value: $0, unit: .meters) }
    }
}

extension PlannedRunEntity {
    /// Nil for a session without a readable date.
    @MainActor
    init?(_ scheduled: ScheduledWorkoutPlan) {
        guard let date = Calendar.current.date(from: scheduled.date) else { return nil }
        self.init(
            id: scheduled.plan.id,
            name: scheduled.plan.displayTitle,
            date: date,
            distanceMeters: scheduled.plan.workout.totalDistance
        )
    }
}

struct PlannedRunQuery: EntityStringQuery {
    @Dependency private var scheduleManager: WorkoutScheduleManager

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PlannedRunEntity] {
        try await upcoming().filter { identifiers.contains($0.id) }
    }

    /// By name, as spoken: "long run" finds "Long Run 18K".
    @MainActor
    func entities(matching string: String) async throws -> [PlannedRunEntity] {
        try await upcoming().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlannedRunEntity] {
        try await upcoming()
    }

    @MainActor
    private func upcoming() async throws -> [PlannedRunEntity] {
        try await scheduleManager.loadScheduleForAction()
        return scheduleManager.upcomingWorkouts.compactMap { PlannedRunEntity($0) }
    }
}
