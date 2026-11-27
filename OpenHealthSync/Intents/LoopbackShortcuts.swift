//
//  LoopbackShortcuts.swift
//  OpenHealthSync
//
//  The actions offered without any setup: in Siri by these phrases, in
//  Spotlight and at the top of the Shortcuts app. Every phrase has to carry
//  the app's name; that is how Siri knows whose action it is.
//

import AppIntents

struct LoopbackShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .orange

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextRunIntent(),
            phrases: [
                "What's my next run in \(.applicationName)",
                "What's my next \(.applicationName) run",
                "Next run in \(.applicationName)",
            ],
            shortTitle: "Next Run",
            systemImageName: "figure.run"
        )
        AppShortcut(
            intent: LastRunIntent(),
            phrases: [
                "How was my last run in \(.applicationName)",
                "How was my last \(.applicationName) run",
                "Last run in \(.applicationName)",
            ],
            shortTitle: "Last Run",
            systemImageName: "stopwatch"
        )
        AppShortcut(
            intent: DoRunTodayIntent(),
            phrases: [
                "Do my next run today in \(.applicationName)",
                "Do my next \(.applicationName) run today",
                "Bring my next run forward in \(.applicationName)",
            ],
            shortTitle: "Do Run Today",
            systemImageName: "calendar.badge.clock"
        )
        AppShortcut(
            intent: MoveRunIntent(),
            phrases: [
                "Move my next run in \(.applicationName)",
                "Move my next \(.applicationName) run",
                "Reschedule my next run in \(.applicationName)",
            ],
            shortTitle: "Move Run",
            systemImageName: "arrow.right.circle"
        )
        AppShortcut(
            intent: SkipRunIntent(),
            phrases: [
                "Skip my next run in \(.applicationName)",
                "Skip my next \(.applicationName) run",
            ],
            shortTitle: "Skip Run",
            systemImageName: "forward.end"
        )
        AppShortcut(
            intent: SetbackCheckInIntent(),
            phrases: [
                "I'm feeling \(\.$status) in \(.applicationName)",
                "Setback check-in in \(.applicationName)",
                "Check in with \(.applicationName)",
            ],
            shortTitle: "Setback Check-In",
            systemImageName: "thermometer.medium"
        )
    }
}
