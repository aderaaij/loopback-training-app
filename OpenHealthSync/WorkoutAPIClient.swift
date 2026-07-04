//
//  WorkoutAPIClient.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 14/03/2026.
//

import Foundation

actor WorkoutAPIClient {
    private var baseURL: URL
    private var apiKey: String

    var isConfigured: Bool { true }

    init(baseURL: String? = nil, apiKey: String? = nil) {
        let info = Bundle.main.infoDictionary ?? [:]
        let urlString = baseURL ?? info["WorkoutAPIBaseURL"] as? String ?? ""
        let key = apiKey ?? info["WorkoutAPIKey"] as? String ?? ""
        self.baseURL = URL(string: urlString) ?? URL(string: "https://localhost")!
        self.apiKey = key
    }

    func configure(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func send(data: Data) async throws {
        let url = baseURL.appendingPathComponent("api/workouts")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Workout Inventory Sync

    func syncInventory(_ inventory: [WorkoutInventoryItem]) async throws {
        let url = baseURL.appendingPathComponent("api/workouts/inventory")

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(inventory)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Workout Queue

    func fetchQueue() async throws -> [QueuedWorkoutComposition] {
        let url = baseURL.appendingPathComponent("api/workouts/queue")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([QueuedWorkoutComposition].self, from: data)
    }

    // MARK: - Pending Actions (edit/delete)

    func fetchPendingActions() async throws -> [PendingWorkoutAction] {
        let url = baseURL.appendingPathComponent("api/workouts/actions")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PendingWorkoutAction].self, from: data)
    }

    func acknowledgePendingAction(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("api/workouts/actions/\(id.uuidString)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Workout Feedback

    func submitFeedback(_ payload: WorkoutFeedbackPayload) async throws {
        let url = baseURL.appendingPathComponent("api/workouts/feedback")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        // 201 Created or 409 Conflict (idempotent) are both acceptable
        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 409 else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Health Metrics

    func sendHealthMetrics(_ payload: HealthMetricsBulkPayload) async throws {
        let url = baseURL.appendingPathComponent("api/health/metrics")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(payload)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Training Plans

    /// Fetches every active plan. A running plan and a strength cycle can be
    /// active simultaneously, so callers split the result by activity type.
    func fetchActivePlans() async throws -> [TrainingPlan] {
        let url = baseURL.appendingPathComponent("api/plans")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "status", value: "active")]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }

        let wrapped = try JSONDecoder().decode([FailableDecodable<TrainingPlan>].self, from: data)
        return wrapped.compactMap(\.value)
    }

    /// Fetches every plan (no status filter), newest first. Used by the plans
    /// browser to group plans into upcoming / current / archived.
    func fetchAllPlans() async throws -> [TrainingPlan] {
        let url = baseURL.appendingPathComponent("api/plans")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }

        // Decode resiliently: a single plan with malformed (LLM-authored)
        // metadata shouldn't blank the entire list.
        let wrapped = try JSONDecoder().decode([FailableDecodable<TrainingPlan>].self, from: data)
        return wrapped.compactMap(\.value)
    }

    // MARK: - Unified Schedule Calendar (runs + strength)

    /// Fetches the merged run + strength agenda, date-sorted with conflict
    /// flags. Dates are "yyyy-MM-dd"; the server defaults to today..+28d
    /// when a bound is omitted.
    func fetchScheduleCalendar(from: String? = nil, to: String? = nil) async throws -> CalendarResponse {
        let url = baseURL.appendingPathComponent("api/schedule/calendar")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let from { queryItems.append(URLQueryItem(name: "from", value: from)) }
        if let to { queryItems.append(URLQueryItem(name: "to", value: to)) }
        if !queryItems.isEmpty { components.queryItems = queryItems }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(CalendarResponse.self, from: data)
    }

    /// Fetches a plan's cadence expanded to concrete dated sessions, with
    /// run-conflict warnings. Used by the strength plan detail screen.
    func fetchPlanSchedule(planId: UUID) async throws -> PlanScheduleResponse {
        let url = baseURL.appendingPathComponent("api/plans/\(planId.uuidString)/schedule")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(PlanScheduleResponse.self, from: data)
    }

    func fetchPlanWorkouts(planId: UUID) async throws -> [PlanWorkout] {
        let url = baseURL.appendingPathComponent("api/plans/\(planId.uuidString)/workouts")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PlanWorkout].self, from: data)
    }

    // MARK: - Plan Workout Completion

    /// Marks a queued plan workout as completed, server stamps completed_at idempotently
    /// (only writes when currently null, so dual-write with inventory sync is safe).
    func markPlanWorkoutCompleted(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("api/queue/\(id.uuidString)/status")

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["status": "completed"])

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Queue Item Status Update

    func updateQueueItemStatus(id: UUID, status: String) async throws {
        let url = baseURL.appendingPathComponent("api/workouts/queue/\(id.uuidString)")

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(["status": status])

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }

    // MARK: - Queue Item Deletion

    func deleteQueueItem(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("api/workouts/queue/\(id.uuidString)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw WorkoutAPIError.serverError(httpResponse.statusCode)
        }
    }
}

enum WorkoutAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Workout API client is not configured"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let code):
            return "Server returned status \(code)"
        }
    }
}

// MARK: - Feedback Payload

/// Codable payload mirroring WorkoutFeedback for API submission.
struct WorkoutFeedbackPayload: Codable, Sendable {
    let id: UUID
    let workoutId: UUID
    let workoutName: String
    let scheduledDate: Date
    let detectedAt: Date
    let acknowledgedAt: Date?
    let reason: String
    let reasonNote: String?
    let action: String
    let newDate: Date?
    let dismissed: Bool
}
