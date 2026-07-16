//
//  NotificationManager.swift
//  OpenHealthSync
//
//  Manages local notification scheduling for missed workout prompts.
//  Notification timing is based on the user's preferred run time
//  stored in @AppStorage("preferredRunTime").
//

import Foundation
import Combine
import UserNotifications
import SwiftUI

enum PreferredRunTime: String, CaseIterable, Identifiable {
    case morning
    case midday
    case evening

    var id: String { rawValue }

    var label: String {
        switch self {
        case .morning: return "Morning"
        case .midday: return "Midday"
        case .evening: return "Evening"
        }
    }

    var description: String {
        switch self {
        case .morning: return "Around 8 AM"
        case .midday: return "Around 12 PM"
        case .evening: return "Around 6 PM"
        }
    }

    /// The hour (0-23) to fire missed workout notifications.
    var notificationHour: Int {
        switch self {
        case .morning: return 8
        case .midday: return 12
        case .evening: return 18
        }
    }
}

@MainActor
class NotificationManager: ObservableObject {
    @Published var isAuthorized = false

    private let center = UNUserNotificationCenter.current()
    private let missedWorkoutCategoryId = "MISSED_WORKOUT"
    private let missedWorkoutRequestPrefix = "missed-workout-"
    private let planCelebrationRequestPrefix = "plan-celebration-"
    private static let notifiedPlansKey = "celebrationNotifiedPlanIds"

    // MARK: - Permission

    func requestPermission() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            isAuthorized = granted
            if granted {
                registerCategories()
            }
        } catch {
            print("Notification permission error: \(error)")
            isAuthorized = false
        }
    }

    func checkAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    // MARK: - Scheduling

    /// Schedule a local notification for missed workouts, timed to the next morning
    /// at the user's preferred run time.
    func scheduleMissedWorkoutNotification(
        workouts: [MissedWorkoutInfo],
        preferredRunTime: PreferredRunTime
    ) async {
        guard isAuthorized, !workouts.isEmpty else { return }

        // Cancel any existing missed workout notifications first
        await cancelPendingMissedWorkoutNotifications()

        let content = UNMutableNotificationContent()
        content.categoryIdentifier = missedWorkoutCategoryId
        content.sound = .default

        if workouts.count == 1 {
            let workout = workouts[0]
            content.title = "Missed workout"
            content.body = "You had \(workout.displayName) scheduled yesterday — want to check in?"
        } else {
            content.title = "Missed workouts"
            content.body = "You have \(workouts.count) missed workouts — want to check in?"
        }

        // Schedule for the next occurrence of the preferred time
        var dateComponents = DateComponents()
        dateComponents.hour = preferredRunTime.notificationHour
        dateComponents.minute = 0

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)

        let request = UNNotificationRequest(
            identifier: "\(missedWorkoutRequestPrefix)batch",
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
        } catch {
            print("Failed to schedule missed workout notification: \(error)")
        }
    }

    /// Fires an immediate local notification when a plan becomes finishable
    /// while the app is backgrounded (a HealthKit background sync just landed
    /// the final run). Tapping it opens the app, which auto-presents the
    /// celebration sheet. Deduplicated per plan in UserDefaults rather than in
    /// memory: background wakes can spawn a fresh process each time.
    ///
    /// Checks the notification-center settings directly instead of
    /// `isAuthorized` — that flag is only populated by the foreground
    /// permission flow, which never runs in a background launch.
    func notifyPlanFinishable(_ plan: TrainingPlan) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        var notifiedIds = Set(UserDefaults.standard.stringArray(forKey: Self.notifiedPlansKey) ?? [])
        guard !notifiedIds.contains(plan.id.uuidString) else { return }

        let content = UNMutableNotificationContent()
        content.title = "You finished \(plan.name) 🎉"
        content.body = "Tap to celebrate and leave feedback for your coach."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(planCelebrationRequestPrefix)\(plan.id.uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )

        do {
            try await center.add(request)
            notifiedIds.insert(plan.id.uuidString)
            UserDefaults.standard.set(Array(notifiedIds), forKey: Self.notifiedPlansKey)
        } catch {
            print("Failed to schedule plan celebration notification: \(error)")
        }
    }

    /// Clears a delivered celebration notification once its plan is completed,
    /// so a stale "you finished" doesn't linger in Notification Center.
    func clearPlanFinishableNotification(planId: UUID) {
        center.removeDeliveredNotifications(
            withIdentifiers: ["\(planCelebrationRequestPrefix)\(planId.uuidString)"]
        )
    }

    /// Cancel all pending missed workout notifications.
    func cancelPendingMissedWorkoutNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let missedIds = pending
            .filter { $0.identifier.hasPrefix(missedWorkoutRequestPrefix) }
            .map(\.identifier)
        if !missedIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: missedIds)
        }
    }

    // MARK: - Categories

    private func registerCategories() {
        let checkInAction = UNNotificationAction(
            identifier: "CHECK_IN",
            title: "Check in",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: missedWorkoutCategoryId,
            actions: [checkInAction, dismissAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([category])
    }
}
