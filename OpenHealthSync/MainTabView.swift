import SwiftUI

enum LBTab: Hashable {
    case training, settings
}

struct MainTabView: View {
    @ObservedObject var workoutManager: WorkoutManager
    @ObservedObject var scheduleManager: WorkoutScheduleManager
    @ObservedObject var missedWorkoutDetector: MissedWorkoutDetector
    @ObservedObject var session: SessionStore
    let onReconnect: (String, String) async throws -> Void

    @State private var tab: LBTab = .training

    var body: some View {
        ZStack(alignment: .bottom) {
            LB.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .training:
                    NavigationStack {
                        TrainingTabView(
                            scheduleManager: scheduleManager,
                            workoutManager: workoutManager,
                            missedWorkoutDetector: missedWorkoutDetector
                        )
                    }
                case .settings:
                    NavigationStack {
                        SettingsTabView(
                            workoutManager: workoutManager,
                            scheduleManager: scheduleManager,
                            session: session,
                            onReconnect: onReconnect
                        )
                    }
                }
            }
            // Reserve room so scroll content clears the floating bar.
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 64) }

            LBTabBar(selection: $tab)
                .padding(.bottom, 8)
        }
    }
}

// MARK: - Floating glass tab bar

struct LBTabBar: View {
    @Binding var selection: LBTab

    var body: some View {
        HStack(spacing: 6) {
            item(.training, icon: "figure.run", title: "Training")
            item(.settings, icon: "gearshape", title: "Settings")
        }
        .padding(7)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(LB.surfaceControl.opacity(0.35)))
        )
        .overlay(
            Capsule(style: .continuous).strokeBorder(LB.lineStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.55), radius: 17, x: 0, y: 12)
    }

    private func item(_ value: LBTab, icon: String, title: String) -> some View {
        let on = selection == value
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
            Text(title)
                .font(.lbBody(14, .semibold))
        }
        .foregroundStyle(on ? LB.accent : LB.textTertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous).fill(on ? LB.accentTint() : .clear)
        )
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { selection = value }
        }
    }
}

// MARK: - Settings Tab

private struct SettingsTabView: View {
    @ObservedObject var workoutManager: WorkoutManager
    @ObservedObject var scheduleManager: WorkoutScheduleManager
    @ObservedObject var session: SessionStore
    let onReconnect: (String, String) async throws -> Void

    var body: some View {
        ServerConfigView(
            mode: .settings,
            session: session,
            onSave: { baseURL, token in
                // Swap in a manually pasted token via the session, verify it,
                // persist, and refresh the data.
                try await onReconnect(baseURL, token)
            },
            onSignOut: {
                Task {
                    await session.signOut()
                }
            },
            onRemoveAllWorkouts: {
                await scheduleManager.removeAll()
            }
        )
    }
}
