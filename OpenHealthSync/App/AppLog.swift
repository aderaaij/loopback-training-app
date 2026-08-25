//
//  AppLog.swift
//  OpenHealthSync
//
//  Category loggers for the app's subsystems. Visible in Xcode's console and
//  in Console.app filtered by the bundle identifier — including on a device
//  with no debugger attached, which is how sync issues in the field get
//  diagnosed. Dynamic values are marked public at the call sites: this is a
//  personal app talking to a self-hosted server, and tokens or credentials
//  never pass through these messages.
//

import Foundation
import os

nonisolated enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.ardenlab.loopback"

    /// Server sync: queue, inventory, plans, calendar, feedback.
    static let sync = Logger(subsystem: subsystem, category: "sync")
    /// WorkoutKit scheduling on the watch: schedule, remove, reschedule, edit.
    static let scheduling = Logger(subsystem: subsystem, category: "scheduling")
    /// HealthKit reads, metrics extraction, and background delivery.
    static let health = Logger(subsystem: subsystem, category: "health")
    /// Local notifications.
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    /// View-layer events with no manager to own them.
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
