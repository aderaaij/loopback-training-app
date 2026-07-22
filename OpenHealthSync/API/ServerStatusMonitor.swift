//
//  ServerStatusMonitor.swift
//  OpenHealthSync
//
//  Publishes the health of the training-server connection. Every request
//  already flows through WorkoutAPIClient.perform(), so recording its result
//  paths keeps the indicator honest without any extra polling traffic.
//

import SwiftUI

/// Connection health derived from the most recent API request.
enum ServerStatus: Equatable {
    /// Nothing recorded yet this launch (or since sign-out).
    case unknown
    /// The last request received an HTTP response — the server is reachable.
    case connected
    /// The last request never got an HTTP response (timeout, DNS, refused).
    case connectionError
    /// The last authenticated request returned 401 — the session is dead.
    case authenticationError
}

@Observable
final class ServerStatusMonitor {
    static let shared = ServerStatusMonitor()

    private(set) var status: ServerStatus = .unknown
    /// Whether the last request went through the alternative (fallback) URL.
    private(set) var viaFallback = false

    func record(_ status: ServerStatus, viaFallback: Bool = false) {
        if status != self.status { self.status = status }
        if viaFallback != self.viaFallback { self.viaFallback = viaFallback }
    }

    /// Called when the session ends or the server changes; the next request
    /// speaks for the new configuration.
    func reset() {
        record(.unknown)
    }
}

// MARK: - Indicator views

extension ServerStatus {
    var dotColor: Color {
        switch self {
        case .unknown: LB.textMuted
        case .connected: LB.green
        case .connectionError: LB.red
        case .authenticationError: LB.amber
        }
    }

    var label: String {
        switch self {
        case .unknown: "Waiting for first request"
        case .connected: "Connected"
        case .connectionError: "Can't reach server"
        case .authenticationError: "Authentication failed"
        }
    }
}

/// Plain colored dot, sized for toolbar or row use.
struct ServerStatusDot: View {
    let status: ServerStatus

    var body: some View {
        Circle()
            .fill(status.dotColor)
            .frame(width: 8, height: 8)
    }
}

/// Settings row: dot + human-readable status.
struct ServerStatusRow: View {
    private var monitor = ServerStatusMonitor.shared

    var body: some View {
        HStack {
            Text("Status")
            Spacer()
            ServerStatusDot(status: monitor.status)
            Text(monitor.status == .connected && monitor.viaFallback
                ? "Connected via fallback"
                : monitor.status.label)
                .foregroundStyle(.secondary)
        }
    }
}

/// Toolbar indicator that stays invisible while everything is fine and shows
/// a warning dot when the server is unreachable or the session died.
struct ServerStatusToolbarDot: View {
    private var monitor = ServerStatusMonitor.shared

    var body: some View {
        switch monitor.status {
        case .unknown, .connected:
            EmptyView()
        case .connectionError, .authenticationError:
            ServerStatusDot(status: monitor.status)
        }
    }
}
