//
//  CalendarSync.swift
//  OpenHealthSync
//
//  Mirrors the training schedule into a "Loopback" calendar in the iOS
//  Calendar app (opt-in, Settings → Training). One-way: the app writes,
//  and edits made in Calendar are overwritten on the next sync.
//
//  Events are recognised by their URL (`loopbacktraining://open?item=<key>`),
//  not by EventKit identifiers, which can change when a calendar syncs.
//  Anything in the calendar without that URL is the user's and is left alone.
//

import EventKit
import Foundation
import HealthKit
import WorkoutKit
import os

// MARK: - Item

/// One day's entry as it should appear in Calendar.
nonisolated struct CalendarSyncItem: Sendable, Equatable {
    /// Stable identity across syncs: the workout id for runs, date + title
    /// for strength sessions (which have no id).
    let key: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let notes: String?
}

extension CalendarSyncItem {
    /// Length given to a run whose duration can't be known up front
    /// (distance or open goals).
    private static let defaultRunLength: TimeInterval = 60 * 60
    nonisolated static let runKeyPrefix = "run-"
    nonisolated static let strengthKeyPrefix = "strength-"

    /// Everything from today on: runs as scheduled on the watch, plus the
    /// strength sessions from the server's agenda. Of earlier days only the
    /// sessions that were done: those still on the watch as complete, and the
    /// plan's completed sessions, which covers one that is no longer on the
    /// watch. A missed or skipped session is never produced, so whatever
    /// Calendar holds for it stays as it was.
    static func items(
        scheduled: [ScheduledWorkoutPlan],
        entries: [CalendarEntry],
        planWorkouts: [PlanWorkout] = [],
        now: Date = Date()
    ) -> [CalendarSyncItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var items: [CalendarSyncItem] = []

        for workout in scheduled {
            guard let start = calendar.date(from: workout.date), start >= today || workout.complete else { continue }
            // A run without a time of day (or at midnight, which is how
            // "no time" arrives from the server) is an all-day entry.
            let hasTime = (workout.date.hour ?? 0) != 0 || (workout.date.minute ?? 0) != 0
            let length = estimatedLength(of: workout.plan.workout) ?? defaultRunLength
            items.append(CalendarSyncItem(
                key: "\(runKeyPrefix)\(workout.plan.id.uuidString)",
                title: workout.plan.displayTitle,
                start: start,
                end: hasTime ? start.addingTimeInterval(length) : start,
                isAllDay: !hasTime,
                notes: nil
            ))
        }

        // The watch's own entry wins: it has the workout's steps, and with
        // them a length.
        var known = Set(items.map(\.key))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        for session in planWorkouts where session.status == "completed" {
            guard let start = session.scheduledDate, start < tomorrow else { continue }
            let key = "\(runKeyPrefix)\(session.id.uuidString)"
            guard known.insert(key).inserted else { continue }
            let time = calendar.dateComponents([.hour, .minute], from: start)
            let hasTime = (time.hour ?? 0) != 0 || (time.minute ?? 0) != 0
            items.append(CalendarSyncItem(
                key: key,
                title: session.title,
                start: start,
                end: hasTime ? start.addingTimeInterval(defaultRunLength) : start,
                isAllDay: !hasTime,
                notes: nil
            ))
        }

        for entry in entries where entry.kind == .strength {
            guard let day = entry.day, day >= today else { continue }
            items.append(CalendarSyncItem(
                key: "\(strengthKeyPrefix)\(entry.date)-\(entry.title)",
                title: entry.title,
                start: day,
                end: day,
                isAllDay: true,
                notes: entry.planName
            ))
        }

        return items
    }

    /// Total time of a custom workout, rounded up to five minutes. Nil when
    /// any step has a goal other than time, since the total is then unknown.
    private static func estimatedLength(of workout: WorkoutPlan.Workout) -> TimeInterval? {
        guard let goals = workout.stepGoals else { return nil }

        var total: TimeInterval = 0
        for (goal, times) in goals {
            guard case .time(let value, let unit) = goal else { return nil }
            total += Measurement(value: value, unit: unit).converted(to: .seconds).value * Double(times)
        }
        guard total > 0 else { return nil }
        return (total / 300).rounded(.up) * 300
    }
}

extension WorkoutPlan.Workout {
    /// Every step's goal with how many times it is run, warm-up and cool-down
    /// included. Nil for anything but a custom workout.
    nonisolated var stepGoals: [(goal: WorkoutGoal, times: Int)]? {
        guard case .custom(let custom) = self else { return nil }
        var goals: [(goal: WorkoutGoal, times: Int)] = []
        if let warmup = custom.warmup { goals.append((warmup.goal, 1)) }
        for block in custom.blocks {
            for step in block.steps { goals.append((step.step.goal, block.iterations)) }
        }
        if let cooldown = custom.cooldown { goals.append((cooldown.goal, 1)) }
        return goals
    }

    /// The whole workout's distance in meters. Nil when any step has a goal
    /// other than distance, since the total is then unknown.
    nonisolated var totalDistance: Double? {
        guard let goals = stepGoals else { return nil }
        var total = 0.0
        for (goal, times) in goals {
            guard case .distance(let value, let unit) = goal else { return nil }
            total += Measurement(value: value, unit: unit).converted(to: .meters).value * Double(times)
        }
        return total > 0 ? total : nil
    }
}

extension WorkoutPlan {
    /// The name shown for a scheduled workout, also reported to the server
    /// in the device inventory.
    var displayTitle: String {
        switch workout {
        case .custom(let custom):
            return custom.displayName ?? "Custom Workout"
        case .goal(let goal):
            return "Goal: \(goal.activity.displayName)"
        case .pacer(let pacer):
            return "Pacer: \(pacer.activity.displayName)"
        case .swimBikeRun:
            return "Swim-Bike-Run"
        @unknown default:
            return "Workout"
        }
    }

    /// The one activity the workout is; nil for a multisport one.
    var activityType: HKWorkoutActivityType? {
        switch workout {
        case .custom(let custom):
            return custom.activity
        case .goal(let goal):
            return goal.activity
        case .pacer(let pacer):
            return pacer.activity
        case .swimBikeRun:
            return nil
        @unknown default:
            return nil
        }
    }
}

// MARK: - Sync

actor CalendarSync {
    static let shared = CalendarSync()

    /// The user's switch in Settings → Training.
    static let enabledKey = "calendarSyncEnabled"
    private static let calendarIdKey = "calendarSyncCalendarID"
    private static let calendarTitle = "Loopback"
    private static let urlScheme = "loopbacktraining"
    /// Days before the earliest done session to search for existing entries.
    private static let movedSessionSlack = 60

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Loopback", category: "calendar")

    /// Created on first use, after access exists: a store made before the
    /// user grants access doesn't see calendars until it is reset.
    private var cachedStore: EKEventStore?

    nonisolated static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Asks for full calendar access (needed to find and update the app's own
    /// events). Returns whether it is granted; iOS only prompts the first time.
    func requestAccess() async -> Bool {
        if Self.hasAccess { return true }
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        cachedStore = nil
        return granted
    }

    // MARK: Sync

    /// Makes the Loopback calendar match `items` from today on: adds what is
    /// missing, updates what moved or was renamed, removes what is gone.
    /// Items before today are sessions that were done: those are added or
    /// corrected, and nothing in the past is ever removed.
    /// With `strengthKnown` false the strength sessions already in Calendar
    /// are kept untouched, whatever `items` says about them.
    func sync(items: [CalendarSyncItem], strengthKnown: Bool) {
        guard Self.isEnabled, Self.hasAccess else { return }
        let store = eventStore()
        guard let calendar = loopbackCalendar(in: store, createIfMissing: true) else { return }

        let today = Calendar.current.startOfDay(for: Date())
        guard let horizon = Calendar.current.date(byAdding: .year, value: 1, to: today) else { return }

        var existing: [String: EKEvent] = [:]
        var changed = false
        do {
            for event in ownEvents(in: calendar, store: store, from: today, to: horizon) {
                // The predicate also returns events that began before today
                // and run into it; those are history.
                guard event.event.startDate >= today else { continue }
                if !strengthKnown, event.key.hasPrefix(CalendarSyncItem.strengthKeyPrefix) { continue }
                if existing[event.key] == nil {
                    existing[event.key] = event.event
                } else {
                    try store.remove(event.event, span: .thisEvent, commit: false)
                    changed = true
                }
            }

            for item in items where item.start >= today && item.start < horizon {
                if !strengthKnown, item.key.hasPrefix(CalendarSyncItem.strengthKeyPrefix) { continue }
                if let event = existing.removeValue(forKey: item.key) {
                    if Self.apply(item, to: event) {
                        try store.save(event, span: .thisEvent, commit: false)
                        changed = true
                    }
                } else {
                    let event = EKEvent(eventStore: store)
                    event.calendar = calendar
                    event.url = Self.url(forKey: item.key)
                    Self.apply(item, to: event)
                    try store.save(event, span: .thisEvent, commit: false)
                    changed = true
                }
            }

            for event in existing.values {
                try store.remove(event, span: .thisEvent, commit: false)
                changed = true
            }

            let done = items.filter { $0.start < today }
            if let earliest = done.map(\.start).min(),
               // Looked for well before the earliest, so a session whose
               // entry sits on the day it was first planned for is found
               // rather than added a second time.
               let from = Calendar.current.date(byAdding: .day, value: -Self.movedSessionSlack, to: earliest) {
                var past: [String: EKEvent] = [:]
                for event in ownEvents(in: calendar, store: store, from: from, to: today)
                where event.event.startDate < today && past[event.key] == nil {
                    past[event.key] = event.event
                }
                for item in done {
                    if let event = past[item.key] {
                        if Self.apply(item, to: event) {
                            try store.save(event, span: .thisEvent, commit: false)
                            changed = true
                        }
                    } else {
                        let event = EKEvent(eventStore: store)
                        event.calendar = calendar
                        event.url = Self.url(forKey: item.key)
                        Self.apply(item, to: event)
                        try store.save(event, span: .thisEvent, commit: false)
                        changed = true
                    }
                }
            }

            if changed { try store.commit() }
        } catch {
            store.reset()
            Self.log.error("Calendar sync failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Copies the item onto the event. Returns whether anything differed, so
    /// an unchanged schedule writes nothing.
    @discardableResult
    private static func apply(_ item: CalendarSyncItem, to event: EKEvent) -> Bool {
        var changed = false
        if event.title != item.title { event.title = item.title; changed = true }
        if event.isAllDay != item.isAllDay { event.isAllDay = item.isAllDay; changed = true }
        if event.startDate != item.start { event.startDate = item.start; changed = true }
        // EventKit stores an all-day event's end as the last second of the
        // day, so comparing it to the item would report a change every time.
        if item.isAllDay {
            if event.endDate == nil || !Calendar.current.isDate(event.endDate, inSameDayAs: item.end) {
                event.endDate = item.end
                changed = true
            }
        } else if event.endDate != item.end {
            event.endDate = item.end
            changed = true
        }
        if (event.notes ?? "") != (item.notes ?? "") { event.notes = item.notes; changed = true }
        return changed
    }

    // MARK: Turning it off

    /// Takes the app's entries out of Calendar. Removes the whole Loopback
    /// calendar, unless the user has put events of their own in it; then only
    /// the app's events go.
    func removeCalendar() {
        defer { UserDefaults.standard.removeObject(forKey: Self.calendarIdKey) }
        guard Self.hasAccess else { return }
        let store = eventStore()
        guard let calendar = loopbackCalendar(in: store, createIfMissing: false) else { return }

        let now = Date()
        guard let from = Calendar.current.date(byAdding: .year, value: -2, to: now),
              let to = Calendar.current.date(byAdding: .year, value: 2, to: now) else { return }
        do {
            let all = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [calendar]))
            let own = ownEvents(in: calendar, store: store, from: from, to: to)
            if own.count == all.count {
                try store.removeCalendar(calendar, commit: true)
            } else {
                for event in own {
                    try store.remove(event.event, span: .thisEvent, commit: false)
                }
                try store.commit()
            }
        } catch {
            store.reset()
            Self.log.error("Removing the calendar failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Internals

    private func eventStore() -> EKEventStore {
        if let cachedStore { return cachedStore }
        let store = EKEventStore()
        cachedStore = store
        return store
    }

    private func ownEvents(
        in calendar: EKCalendar,
        store: EKEventStore,
        from: Date,
        to: Date
    ) -> [(key: String, event: EKEvent)] {
        store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: [calendar]))
            .compactMap { event in
                Self.key(from: event.url).map { (key: $0, event: event) }
            }
    }

    /// The remembered calendar; failing that one named "Loopback" (a
    /// reinstall forgets the id while the calendar lives on in iCloud);
    /// failing that a new one.
    private func loopbackCalendar(in store: EKEventStore, createIfMissing: Bool) -> EKCalendar? {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.calendarIdKey),
           let calendar = store.calendar(withIdentifier: id),
           calendar.allowsContentModifications {
            return calendar
        }
        if let calendar = store.calendars(for: .event).first(where: {
            $0.title == Self.calendarTitle && $0.allowsContentModifications
        }) {
            defaults.set(calendar.calendarIdentifier, forKey: Self.calendarIdKey)
            return calendar
        }
        guard createIfMissing else { return nil }

        // Where the user's new events normally go, then iCloud, then on-device.
        // Some accounts (Exchange, subscribed) refuse new calendars, hence the
        // fallbacks.
        let sources = [
            store.defaultCalendarForNewEvents?.source,
            store.sources.first { $0.sourceType == .calDAV && $0.title == "iCloud" },
            store.sources.first { $0.sourceType == .local },
        ].compactMap { $0 }

        for source in sources {
            let calendar = EKCalendar(for: .event, eventStore: store)
            calendar.title = Self.calendarTitle
            calendar.cgColor = CGColor(srgbRed: 1.0, green: 0x6A / 255.0, blue: 0x3D / 255.0, alpha: 1)
            calendar.source = source
            do {
                try store.saveCalendar(calendar, commit: true)
                defaults.set(calendar.calendarIdentifier, forKey: Self.calendarIdKey)
                return calendar
            } catch {
                store.reset()
                Self.log.error("Couldn't create the calendar in \(source.title, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return nil
    }

    private static func url(forKey key: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "item", value: key)]
        return components.url
    }

    private static func key(from url: URL?) -> String? {
        guard let url, url.scheme == urlScheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first { $0.name == "item" }?.value
    }
}
