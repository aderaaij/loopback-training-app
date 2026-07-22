import SwiftUI

struct MainTabView: View {
    var workoutManager: WorkoutManager
    var scheduleManager: WorkoutScheduleManager
    var missedWorkoutDetector: MissedWorkoutDetector
    var session: SessionStore
    let onReconnect: (String, String) async throws -> Void

    @State private var showingSettings = false

    var body: some View {
        TabView {
            Tab("Training", systemImage: "figure.run") {
                NavigationStack {
                    TrainingTabView(
                        scheduleManager: scheduleManager,
                        workoutManager: workoutManager,
                        missedWorkoutDetector: missedWorkoutDetector
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showingSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                }
            }

            Tab("Trends", systemImage: "chart.line.uptrend.xyaxis") {
                NavigationStack {
                    TrendsView(
                        apiClient: workoutManager.apiClient,
                        missedWorkoutDetector: missedWorkoutDetector
                    )
                }
            }

            Tab("Plans", systemImage: "calendar.badge.clock") {
                NavigationStack {
                    PlansListView(scheduleManager: scheduleManager)
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(
                session: session,
                onReconnect: onReconnect,
                onSignOut: {
                    Task { await session.signOut() }
                },
                onRemoveAllWorkouts: {
                    await scheduleManager.removeAll()
                }
            )
        }
    }
}
