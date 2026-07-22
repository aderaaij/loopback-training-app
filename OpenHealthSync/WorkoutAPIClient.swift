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

    // The API speaks ISO-8601 dates in both directions; every endpoint goes
    // through these shared coders so no method can drift to a different
    // date strategy.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(baseURL: String? = nil, apiKey: String? = nil) {
        self.baseURL = URL(string: baseURL ?? "") ?? URL(string: "https://localhost")!
        self.apiKey = apiKey ?? ""
    }

    func configure(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    // MARK: - Request Engine

    /// Builds, sends, and validates every request. A 401 posts
    /// `.trainingAPIUnauthorized` (dead session → app routes to login) unless
    /// `signalsUnauthorized` is false — endpoints that probe candidate
    /// credentials or run during sign-out must surface auth failures locally
    /// instead of wiping the current session.
    ///
    /// Status codes in `accepting` are returned as success so callers can
    /// branch on them (404 → nil, 409 → idempotent create, ...).
    @discardableResult
    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accepting extraOK: Set<Int> = [],
        signalsUnauthorized: Bool = true,
        timeout: TimeInterval? = nil,
        on overrideURL: URL? = nil,
        authenticated: Bool = true
    ) async throws -> (data: Data, status: Int) {
        var url = (overrideURL ?? baseURL).appendingPathComponent(path)
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            url = components.url!
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if authenticated {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let timeout {
            request.timeoutInterval = timeout
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw WorkoutAPIError.invalidResponse
        }
        let code = http.statusCode
        if (200...299).contains(code) || extraOK.contains(code) {
            return (data, code)
        }
        if code == 401, signalsUnauthorized {
            NotificationCenter.default.post(name: .trainingAPIUnauthorized, object: nil)
            throw WorkoutAPIError.unauthorized
        }
        throw WorkoutAPIError.serverError(code)
    }

    /// `perform` + decode with the shared ISO-8601 decoder.
    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        signalsUnauthorized: Bool = true
    ) async throws -> T {
        let (data, _) = try await perform(
            method, path,
            query: query,
            body: body,
            signalsUnauthorized: signalsUnauthorized
        )
        return try Self.decoder.decode(T.self, from: data)
    }

    /// Performs a lightweight authenticated request to verify the current
    /// base URL and API key. Throws on an unreachable host or a non-2xx
    /// (e.g. 401 for a bad key) so callers can surface a connection result.
    /// Does not signal unauthorized: this verifies a candidate credential
    /// (e.g. a pasted token in Settings) and a 401 here must surface as an
    /// error, not sign the current session out.
    func checkConnection() async throws {
        try await perform("GET", "api/plans", signalsUnauthorized: false, timeout: 15)
    }

    // MARK: - Authentication

    /// Exchanges username + password for a bearer token. Unauthenticated by
    /// design; maps auth-specific status codes to typed errors so the login
    /// UI can message them (a 401 here is a bad password, not a dead session).
    func login(baseURL: URL, username: String, password: String, deviceName: String) async throws -> LoginResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "username": username,
            "password": password,
            "deviceName": deviceName,
        ])

        let (data, status) = try await perform(
            "POST", "api/auth/login",
            body: body,
            accepting: [401, 429],
            timeout: 20,
            on: baseURL,
            authenticated: false
        )

        switch status {
        case 401: throw WorkoutAPIError.invalidCredentials
        case 429: throw WorkoutAPIError.rateLimited
        default: return try Self.decoder.decode(LoginResponse.self, from: data)
        }
    }

    /// Current user + their tokens. Used to populate "Signed in as …".
    /// Doesn't signal unauthorized: called while applying a candidate manual
    /// token, before the session is established.
    func fetchMe() async throws -> MeResponse {
        try await request("GET", "api/auth/me", signalsUnauthorized: false)
    }

    /// Revokes a token by id (logout / sign out a device). 204 = revoked,
    /// 404 = already gone — both treated as success. Doesn't signal
    /// unauthorized: runs during sign-out, when the session is being cleared
    /// anyway.
    func revokeToken(id: String) async throws {
        try await perform("DELETE", "api/auth/tokens/\(id)", accepting: [404], signalsUnauthorized: false)
    }

    // MARK: - Workout Upload

    func send(data: Data) async throws {
        try await perform("POST", "api/workouts", body: data)
    }

    // MARK: - Workout History (server-side aggregates & linkage)

    /// Per-period aggregates over the full server-side workout history,
    /// newest period first. Volume is tiny (one row per period per activity),
    /// so there's no pagination. Periods with no workouts are simply absent —
    /// callers fill gaps when charting.
    func fetchWorkoutSummary(period: String, activityType: String? = nil) async throws -> [ServerWorkoutSummaryRow] {
        var query = [URLQueryItem(name: "period", value: period)]
        if let activityType {
            query.append(URLQueryItem(name: "activity_type", value: activityType))
        }
        return try await request("GET", "api/workouts/summary", query: query)
    }

    /// Authoritative plan linkage for a synced workout (queue item, plan,
    /// feedback). `id` is the HealthKit UUID — the server's workout PK.
    /// A 404 means the workout isn't on the server (not synced yet, or a
    /// different account) — that's a normal case and returns nil; only a 401
    /// goes through the session-wipe path.
    func fetchWorkoutContext(id: UUID) async throws -> WorkoutContext? {
        let (data, status) = try await perform("GET", "api/workouts/\(id.uuidString)/context", accepting: [404])
        if status == 404 { return nil }
        return try Self.decoder.decode(WorkoutContext.self, from: data)
    }

    // MARK: - Workout Inventory Sync

    func syncInventory(_ inventory: [WorkoutInventoryItem]) async throws {
        try await perform("PUT", "api/workouts/inventory", body: Self.encoder.encode(inventory))
    }

    // MARK: - Workout Queue

    func fetchQueue() async throws -> [QueuedWorkoutComposition] {
        try await request("GET", "api/workouts/queue")
    }

    func updateQueueItemStatus(id: UUID, status: String) async throws {
        try await perform(
            "PATCH", "api/workouts/queue/\(id.uuidString)",
            body: Self.encoder.encode(["status": status])
        )
    }

    func deleteQueueItem(id: UUID) async throws {
        try await perform("DELETE", "api/workouts/queue/\(id.uuidString)")
    }

    /// Marks a queued plan workout as completed, server stamps completed_at idempotently
    /// (only writes when currently null, so dual-write with inventory sync is safe).
    func markPlanWorkoutCompleted(id: UUID) async throws {
        try await perform(
            "PATCH", "api/queue/\(id.uuidString)/status",
            body: Self.encoder.encode(["status": "completed"])
        )
    }

    // MARK: - Pending Actions (edit/delete)

    func fetchPendingActions() async throws -> [PendingWorkoutAction] {
        try await request("GET", "api/workouts/actions")
    }

    func acknowledgePendingAction(id: UUID) async throws {
        try await perform("DELETE", "api/workouts/actions/\(id.uuidString)")
    }

    // MARK: - Workout Feedback

    /// 201 Created or 409 Conflict (idempotent re-submit) are both acceptable.
    func submitFeedback(_ payload: WorkoutFeedbackPayload) async throws {
        try await perform("POST", "api/workouts/feedback", body: Self.encoder.encode(payload), accepting: [409])
    }

    // MARK: - Health Metrics

    func sendHealthMetrics(_ payload: HealthMetricsBulkPayload) async throws {
        try await perform("POST", "api/health/metrics", body: Self.encoder.encode(payload))
    }

    // MARK: - Plan Notes (coach memory)

    /// Fetches existing notes for a conversation (used to dedupe onboarding
    /// re-runs). Query params are snake_case; response fields are camelCase.
    func fetchPlanNotes(conversationId: String, limit: Int = 50) async throws -> [PlanNote] {
        try await request("GET", "api/plan-notes", query: [
            URLQueryItem(name: "conversation_id", value: conversationId),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    /// Creates a new plan note (201 → the created note). Request body uses
    /// camelCase aliases (`conversationId`).
    @discardableResult
    func createPlanNote(_ note: PlanNoteCreate) async throws -> PlanNote {
        try await request("POST", "api/plan-notes", body: Self.encoder.encode(note))
    }

    /// Partial-updates an existing note by id (used to patch onboarding notes
    /// on re-run instead of creating duplicates).
    @discardableResult
    func updatePlanNote(id: String, _ update: PlanNoteUpdate) async throws -> PlanNote {
        try await request("PATCH", "api/plan-notes/\(id)", body: Self.encoder.encode(update))
    }

    // MARK: - Training Plans

    /// Fetches every active plan. A running plan and a strength cycle can be
    /// active simultaneously, so callers split the result by activity type.
    func fetchActivePlans() async throws -> [TrainingPlan] {
        try await fetchPlans(query: [URLQueryItem(name: "status", value: "active")])
    }

    /// Fetches every plan (no status filter), newest first. Used by the plans
    /// browser to group plans into upcoming / current / archived.
    func fetchAllPlans() async throws -> [TrainingPlan] {
        try await fetchPlans(query: [])
    }

    /// Decodes resiliently: a single plan with malformed (LLM-authored)
    /// metadata shouldn't blank the entire list.
    private func fetchPlans(query: [URLQueryItem]) async throws -> [TrainingPlan] {
        let wrapped: [FailableDecodable<TrainingPlan>] = try await request("GET", "api/plans", query: query)
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
        var body: [String: Any] = [:]
        if let feedback, !feedback.isEmpty { body["feedback"] = feedback }
        if let rating { body["rating"] = rating }

        let (data, status) = try await perform(
            "POST", "api/plans/\(id.uuidString)/complete",
            body: JSONSerialization.data(withJSONObject: body),
            accepting: [400]
        )
        if status == 400 { throw WorkoutAPIError.planNotActive }
        return try Self.decoder.decode(PlanCompletionResponse.self, from: data)
    }

    // MARK: - Unified Schedule Calendar (runs + strength)

    /// Fetches the merged run + strength agenda, date-sorted with conflict
    /// flags. Dates are "yyyy-MM-dd"; the server defaults to today..+28d
    /// when a bound is omitted.
    func fetchScheduleCalendar(from: String? = nil, to: String? = nil) async throws -> CalendarResponse {
        var query: [URLQueryItem] = []
        if let from { query.append(URLQueryItem(name: "from", value: from)) }
        if let to { query.append(URLQueryItem(name: "to", value: to)) }
        return try await request("GET", "api/schedule/calendar", query: query)
    }

    /// Fetches a plan's cadence expanded to concrete dated sessions, with
    /// run-conflict warnings. Used by the strength plan detail screen.
    func fetchPlanSchedule(planId: UUID) async throws -> PlanScheduleResponse {
        try await request("GET", "api/plans/\(planId.uuidString)/schedule")
    }

    func fetchPlanWorkouts(planId: UUID) async throws -> [PlanWorkout] {
        try await request("GET", "api/plans/\(planId.uuidString)/workouts")
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
