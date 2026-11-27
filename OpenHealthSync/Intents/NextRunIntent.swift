//
//  NextRunIntent.swift
//  OpenHealthSync
//
//  "What's my next run?" Answered from the phone's own copy of the watch's
//  schedule, so it works without the server; the coach's note on the session
//  comes along when the plan is on disk.
//

import AppIntents
import SwiftUI
import WorkoutKit

struct NextRunIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Run"
    static let description = IntentDescription("Tells you which planned run is next, and when.")

    @Dependency private var session: SessionStore
    @Dependency private var scheduleManager: WorkoutScheduleManager

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<PlannedRunEntity?> & ProvidesDialog & ShowsSnippetView {
        guard session.isAuthenticated else { throw LoopbackIntentError.notSignedIn }
        try await scheduleManager.loadScheduleForAction()

        let next = scheduleManager.upcomingWorkouts.lazy.compactMap { PlannedRunEntity($0) }.first
        guard let next else {
            return .result(value: nil, dialog: "You have no runs planned.") {
                NextRunSnippet(run: nil)
            }
        }

        let note = scheduleManager.planWorkouts.first { $0.id == next.id }?.description
        let distance = next.distance.map {
            IntentPhrasing.plannedDistance(meters: $0.converted(to: .meters).value, units: .current)
        }
        return .result(
            value: next,
            dialog: "Your next run is \(next.name), \(IntentPhrasing.when(next.date))."
        ) {
            NextRunSnippet(run: .init(
                name: next.name,
                when: IntentPhrasing.when(next.date),
                distance: distance,
                note: note
            ))
        }
    }
}

/// The card under the answer. It brings its own warm-black ground: Siri and
/// Shortcuts draw it on their sheet with a light color scheme whatever the
/// system is set to, so text in the system's own colors came out dark on a
/// dark sheet. System fonts, because the app's aren't loaded where it is
/// drawn.
struct NextRunSnippet: View {
    struct Run {
        let name: String
        let when: String
        let distance: String?
        let note: String?
    }

    let run: Run?

    var body: some View {
        if let run {
            VStack(alignment: .leading, spacing: LB.Space.xs) {
                Text(run.name)
                    .font(.headline)
                    .foregroundStyle(LB.textPrimary)
                HStack(spacing: LB.Space.xs) {
                    Text(run.when.prefix(1).uppercased() + run.when.dropFirst())
                    if let distance = run.distance {
                        Text("·")
                        Text(distance)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(LB.textBright)
                if let note = run.note, !note.isEmpty {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(LB.textSecondary)
                        .lineLimit(4)
                        .padding(.top, LB.Space.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(LB.Space.lg)
            .background(LB.surface, in: RoundedRectangle(cornerRadius: LB.Radius.card))
            .padding(.horizontal, LB.Space.lg)
            .padding(.bottom, LB.Space.sm)
        }
    }
}
