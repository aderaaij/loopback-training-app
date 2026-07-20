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
        self.baseURL = URL(string: baseURL ?? "") ?? URL(string: "https://localhost")!
        self.apiKey = apiKey ?? ""
    }

    func configure(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    /// Performs a lightweight authenticated request to verify the current
    /// base URL and API key. Throws on an unreachable host or a non-2xx
    /// (e.g. 401 for a bad key) so callers can surface a connection result.
    func checkConnection() async throws {
        let url = baseURL.appendingPathComponent("api/plans")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: request)

        // Intentionally does NOT post .trainingAPIUnauthorized: this verifies a
        // candidate credential (e.g. a pasted token in Settings) and a 401 here
        // must surface as an error, not sign the current session out.
        guard let http = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WorkoutAPIError.serverError(http.statusCode)
        }
    }

    // MARK: - Authentication

    /// Exchanges username + password for a bearer token. Unauthenticated by
    /// design; maps auth-specific status codes to typed errors so the login
    /// UI can message them (a 401 here is a bad password, not a dead session).
    func login(baseURL: URL, username: String, password: String, deviceName: String) async throws -> LoginResponse {
        let url = baseURL.appendingPathComponent("api/auth/login")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
            "deviceName": deviceName,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }
        switch http.statusCode {
        case 200...299: break
        case 401: throw WorkoutAPIError.invalidCredentials
        case 429: throw WorkoutAPIError.rateLimited
        default: throw WorkoutAPIError.serverError(http.statusCode)
        }

        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    /// Current user + their tokens. Used to populate "Signed in as …".
    func fetchMe() async throws -> MeResponse {
        let url = baseURL.appendingPathComponent("api/auth/me")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WorkoutAPIError.invalidResponse
        }

        return try JSONDecoder().decode(MeResponse.self, from: data)
    }

    /// Revokes a token by id (logout / sign out a device). 204 = revoked,
    /// 404 = already gone — both treated as success.
    func revokeToken(id: String) async throws {
        let url = baseURL.appendingPathComponent("api/auth/tokens/\(id)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) || http.statusCode == 404 else {
            throw WorkoutAPIError.serverError(http.statusCode)
        }
    }

    // MARK: - Response Validation

    /// Central response check for authenticated data endpoints. A 401 means the
    /// session died (token revoked/expired, account disabled), so it posts
    /// `.trainingAPIUnauthorized` for the app to route back to login.
    private func validate(_ response: URLResponse, accepting extraOK: Set<Int> = []) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }
        let code = http.statusCode
        if (200...299).contains(code) || extraOK.contains(code) { return }
        if code == 401 {
            NotificationCenter.default.post(name: .trainingAPIUnauthorized, object: nil)
            throw WorkoutAPIError.unauthorized
        }
        throw WorkoutAPIError.serverError(code)
    }

    func send(data: Data) async throws {
        let url = baseURL.appendingPathComponent("api/workouts")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)

        try validate(response)
    }

    // MARK: - Workout History (server-side aggregates & linkage)

    /// Per-period aggregates over the full server-side workout history,
    /// newest period first. Volume is tiny (one row per period per activity),
    /// so there's no pagination. Periods with no workouts are simply absent —
    /// callers fill gaps when charting.
    func fetchWorkoutSummary(period: String, activityType: String? = nil) async throws -> [ServerWorkoutSummaryRow] {
        let url = baseURL.appendingPathComponent("api/workouts/summary")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "period", value: period)]
        if let activityType {
            queryItems.append(URLQueryItem(name: "activity_type", value: activityType))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response)

        return try JSONDecoder().decode([ServerWorkoutSummaryRow].self, from: data)
    }

    /// Authoritative plan linkage for a synced workout (queue item, plan,
    /// feedback). `id` is the HealthKit UUID — the server's workout PK.
    /// A 404 means the workout isn't on the server (not synced yet, or a
    /// different account) — that's a normal case and returns nil; only a 401
    /// goes through the session-wipe path in `validate`.
    func fetchWorkoutContext(id: UUID) async throws -> WorkoutContext? {
        let url = baseURL.appendingPathComponent("api/workouts/\(id.uuidString)/context")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response, accepting: [404])
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }

        return try JSONDecoder().decode(WorkoutContext.self, from: data)
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

        try validate(response)
    }

    // MARK: - Workout Queue

    func fetchQueue() async throws -> [QueuedWorkoutComposition] {
        let url = baseURL.appendingPathComponent("api/workouts/queue")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response)

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

        try validate(response)

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

        try validate(response)
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

        // 201 Created or 409 Conflict (idempotent) are both acceptable
        try validate(response, accepting: [409])
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

        try validate(response)
    }

    // MARK: - Plan Notes (coach memory)

    /// Fetches existing notes for a conversation (used to dedupe onboarding
    /// re-runs). Query params are snake_case; response fields we decode are
    /// camelCase, so a plain decoder is correct.
    func fetchPlanNotes(conversationId: String, limit: Int = 50) async throws -> [PlanNote] {
        let url = baseURL.appendingPathComponent("api/plan-notes")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "conversation_id", value: conversationId),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response)

        return try JSONDecoder().decode([PlanNote].self, from: data)
    }

    /// Creates a new plan note (201 → the created note). Request body uses
    /// camelCase aliases (`conversationId`).
    @discardableResult
    func createPlanNote(_ note: PlanNoteCreate) async throws -> PlanNote {
        let url = baseURL.appendingPathComponent("api/plan-notes")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(note)

        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response)

        return try JSONDecoder().decode(PlanNote.self, from: data)
    }

    /// Partial-updates an existing note by id (used to patch onboarding notes
    /// on re-run instead of creating duplicates).
    @discardableResult
    func updatePlanNote(id: String, _ update: PlanNoteUpdate) async throws -> PlanNote {
        let url = baseURL.appendingPathComponent("api/plan-notes/\(id)")

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(update)

        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response)

        return try JSONDecoder().decode(PlanNote.self, from: data)
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

        try validate(response)

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

        try validate(response)

        // Decode resiliently: a single plan with malformed (LLM-authored)
        // metadata shouldn't blank the entire list.
        let wrapped = try JSONDecoder().decode([FailableDecodable<TrainingPlan>].self, from: data)
        return wrapped.compactMap(\.value)
    }

    // MARK: - Plan Completion (celebration flow)

    /// Confirms a finishable plan as completed, optionally attaching a 1–5
    /// rating and free-text feedback. The server stores the feedback as a plan
    /// note the coach LLM reads when shaping the next block — nothing more to
    /// deliver from the app. A 400 means another surface (dashboard / coach)
    /// completed it first; that maps to `.planNotActive` so callers refresh
    /// instead of erroring.
    func completePlan(id: UUID, feedback: String?, rating: Int?) async throws -> PlanCompletionResponse {
        let url = baseURL.appendingPathComponent("api/plans/\(id.uuidString)/complete")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [:]
        if let feedback, !feedback.isEmpty { body["feedback"] = feedback }
        if let rating { body["rating"] = rating }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 400 {
            throw WorkoutAPIError.planNotActive
        }
        try validate(response)

        return try JSONDecoder().decode(PlanCompletionResponse.self, from: data)
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

        try validate(response)

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

        try validate(response)

        return try JSONDecoder().decode(PlanScheduleResponse.self, from: data)
    }

    func fetchPlanWorkouts(planId: UUID) async throws -> [PlanWorkout] {
        let url = baseURL.appendingPathComponent("api/plans/\(planId.uuidString)/workouts")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        try validate(response)

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

        try validate(response)
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

        try validate(response)
    }

    // MARK: - Queue Item Deletion

    func deleteQueueItem(id: UUID) async throws {
        let url = baseURL.appendingPathComponent("api/workouts/queue/\(id.uuidString)")

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        try validate(response)
    }
}

extension Notification.Name {
    /// Posted by the API client when an authenticated request returns 401,
    /// signalling the session is no longer valid and the app should sign out.
    nonisolated static let trainingAPIUnauthorized = Notification.Name("trainingAPIUnauthorized")
}

enum WorkoutAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case serverError(Int)
    case unauthorized
    case invalidCredentials
    case rateLimited
    case planNotActive

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Workout API client is not configured"
        case .invalidResponse:
            return "Invalid response from server"
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .invalidCredentials:
            return "Incorrect username or password."
        case .rateLimited:
            return "Too many attempts. Wait a minute and try again."
        case .planNotActive:
            return "This plan was already completed on another device."
        case .serverError(let code):
            switch code {
            case 401, 403: return "Authentication failed — check your credentials"
            case 404: return "Not found — check the server URL"
            default: return "Server returned status \(code)"
            }
        }
    }
}

// MARK: - Auth Models
//
// Pure data models. Marked `nonisolated` because the project defaults types to
// @MainActor (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor); without this their
// Codable conformances would be main-actor-isolated and can't be used from the
// WorkoutAPIClient actor.

nonisolated struct AuthUser: Decodable, Sendable {
    let id: String
    let username: String
    let displayName: String
    let role: String
}

nonisolated struct LoginResponse: Decodable, Sendable {
    let token: String
    let tokenId: String
    let user: AuthUser
}

nonisolated struct AuthToken: Decodable, Sendable {
    let id: String
    let name: String?
    let createdAt: String?
    let lastUsedAt: String?
    let expiresAt: String?
}

nonisolated struct MeResponse: Decodable, Sendable {
    let user: AuthUser
    let tokens: [AuthToken]?
}

// MARK: - Feedback Payload

/// Codable payload mirroring WorkoutFeedback for API submission.
nonisolated struct WorkoutFeedbackPayload: Codable, Sendable {
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
