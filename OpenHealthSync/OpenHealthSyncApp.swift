//
//  OpenHealthSyncApp.swift
//  OpenHealthSync
//
//  Created by Arden de Raaij on 13/03/2026.
//

import SwiftUI
import SwiftData
import WorkoutKit
import OpenWearablesHealthSDK

@main
struct SomaticApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var health = HealthManager()
    @StateObject private var workoutManager: WorkoutManager
    @StateObject private var scheduleManager: WorkoutScheduleManager
    @StateObject private var missedWorkoutDetector = MissedWorkoutDetector()
    @StateObject private var notificationManager = NotificationManager()
    @StateObject private var backgroundSyncManager: BackgroundSyncManager
    @StateObject private var session: SessionStore

    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("openWearablesEnabled") private var openWearablesEnabled: Bool = false
    @AppStorage("healthMetricsSyncEnabled") private var healthMetricsSyncEnabled: Bool = true
    @AppStorage("serverURL") private var owServerURL: String = ""
    @AppStorage("appearanceMode") private var appearanceMode: String = AppearanceMode.system.rawValue

    @Environment(\.scenePhase) private var scenePhase

    private let apiClient: WorkoutAPIClient
    private let healthMetricsSyncer: HealthMetricsSyncer

    init() {
        // Resolve the current credentials (migrating any legacy API key into the
        // Keychain) so the live clients are configured synchronously at launch.
        let creds = SessionStore.resolveCredentials()

        let client = WorkoutAPIClient(baseURL: creds.serverURL, apiKey: creds.token)
        self.apiClient = client

        let syncer = HealthMetricsSyncer(apiClient: client)
        self.healthMetricsSyncer = syncer

        let wm = WorkoutManager()
        wm.configure(serverURL: creds.serverURL, apiKey: creds.token)
        let sm = WorkoutScheduleManager(apiClient: client)
        wm.scheduleManager = sm
        _workoutManager = StateObject(wrappedValue: wm)
        _scheduleManager = StateObject(wrappedValue: sm)
        _backgroundSyncManager = StateObject(wrappedValue: BackgroundSyncManager(
            workoutManager: wm,
            healthMetricsSyncer: syncer
        ))
        _session = StateObject(wrappedValue: SessionStore(apiClient: client, workoutManager: wm))
    }

    var body: some Scene {
        WindowGroup {
            appRoot
                .tint(LB.accent)
                .preferredColorScheme(.dark) // Loopback is a dark-only, warm-black theme
        }
        .modelContainer(for: WorkoutFeedback.self)
    }

    @ViewBuilder
    private var appRoot: some View {
        if !session.isAuthenticated {
            NavigationStack {
                LoginView(session: session)
            }
        } else {
            MainTabView(
                health: health,
                workoutManager: workoutManager,
                scheduleManager: scheduleManager,
                missedWorkoutDetector: missedWorkoutDetector,
                session: session,
                onReconnect: { baseURL, token in
                    // Advanced: swap in a manually pasted token, then refresh.
                    try await session.applyManualToken(serverURL: baseURL, token: token)
                    await reloadAll()
                }
            )
            .environmentObject(scheduleManager)
            // Any /api call returning 401 signals a dead session → sign out.
            .onReceive(NotificationCenter.default.publisher(for: .trainingAPIUnauthorized)) { _ in
                session.handleUnauthorized()
            }
            .onAppear {
                // Restore OpenWearables session if enabled
                if openWearablesEnabled && !owServerURL.isEmpty {
                    if !health.restoreSession(host: owServerURL) {
                        // Session restore failed — don't wipe Training API config
                    }
                    health.onSyncCompleted = { [weak workoutManager] in
                        Task {
                            await workoutManager?.extractNewWorkouts()
                        }
                    }
                }
                Task {
                    // Only prompt once the user is actually signed in.
                    guard session.isAuthenticated else { return }
                    await notificationManager.requestPermission()
                }
            }
            .task {
                // MainTabView only renders when authenticated, but an in-flight
                // task can outlive a sign-out (e.g. a 401 mid-session); guard so
                // permission prompts never fire on the way to the login screen.
                guard session.isAuthenticated else { return }

                await scheduleManager.requestAuthorization()
                await scheduleManager.loadScheduledWorkouts()
                await scheduleManager.autoSync()
                await scheduleManager.loadActivePlan()

                // Request HealthKit auth for health metrics and set up background sync
                if healthMetricsSyncEnabled {
                    _ = await healthMetricsSyncer.requestAuthorization()
                    try? await healthMetricsSyncer.syncMetrics()
                }

                // Register HealthKit background observers for automatic sync
                await backgroundSyncManager.setUp()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        await scheduleManager.loadScheduledWorkouts()
                        await scheduleManager.autoSync()
                        await detectAndNotify()

                        // Sync health metrics on foreground
                        if healthMetricsSyncEnabled {
                            try? await healthMetricsSyncer.syncMetrics()
                        }
                    }
                }
            }
        }
    }

    /// Refreshes everything after a credential change so it takes effect
    /// immediately instead of only after the next app launch.
    private func reloadAll() async {
        await scheduleManager.loadScheduledWorkouts()
        await scheduleManager.autoSync()
        await scheduleManager.loadActivePlan()
        if healthMetricsSyncEnabled {
            try? await healthMetricsSyncer.syncMetrics()
        }
    }

    private func detectAndNotify() async {
        guard let container = try? ModelContainer(for: WorkoutFeedback.self) else { return }
        let context = ModelContext(container)

        missedWorkoutDetector.checkForMissedWorkouts(
            scheduledWorkouts: scheduleManager.scheduledWorkouts,
            modelContext: context
        )

        if !missedWorkoutDetector.missedWorkouts.isEmpty {
            let runTime = PreferredRunTime(rawValue: preferredRunTime) ?? .morning
            await notificationManager.scheduleMissedWorkoutNotification(
                workouts: missedWorkoutDetector.missedWorkouts,
                preferredRunTime: runTime
            )
        } else {
            await notificationManager.cancelPendingMissedWorkoutNotifications()
        }
    }
}
