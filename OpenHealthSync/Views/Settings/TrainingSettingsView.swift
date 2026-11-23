//
//  TrainingSettingsView.swift
//  OpenHealthSync
//
//  Training preferences: preferred run time, week start, the iOS Calendar
//  mirror, distance alerts on the watch and display units.
//

import SwiftUI

struct TrainingSettingsView: View {
    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    @AppStorage(CalendarSync.enabledKey) private var calendarSyncEnabled = false
    @AppStorage(DistanceAlert.storageKey) private var distanceAlert: DistanceAlert = .off
    @AppStorage(DistanceAlert.customValueKey) private var distanceAlertCustomValue = DistanceAlert.defaultCustomValue
    @State private var showingCalendarAccessAlert = false
    /// The setting the watch's runs were last built for; nil until the
    /// screen has appeared, which is not a change.
    @State private var appliedDistanceAlertSetting: String?
    @Environment(WorkoutScheduleManager.self) private var scheduleManager
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("When do you usually run?") {
                Picker("Preferred time", selection: Binding(
                    get: { PreferredRunTime(rawValue: preferredRunTime) ?? .morning },
                    set: { preferredRunTime = $0.rawValue }
                )) {
                    ForEach(PreferredRunTime.allCases) { time in
                        Text("\(time.label) — \(time.description)").tag(time)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section {
                Picker("Week starts on", selection: $weekStartsOnMonday) {
                    Text("Monday").tag(true)
                    Text("Sunday").tag(false)
                }
                Toggle("Show in iOS Calendar", isOn: calendarSyncBinding)
            } header: {
                Text("Calendar")
            } footer: {
                Text("Adds your upcoming runs and strength sessions to a Loopback calendar in the Calendar app and keeps them up to date. Turning this off removes them again.")
            }

            Section {
                Picker("Distance alerts", selection: $distanceAlert) {
                    Text("Off").tag(DistanceAlert.off)
                    Text("Every kilometer").tag(DistanceAlert.kilometer)
                    Text("Every mile").tag(DistanceAlert.mile)
                    Text("Every \(distanceAlertCustomValue) \(units.distanceUnit)").tag(DistanceAlert.custom)
                }
                if distanceAlert == .custom {
                    Stepper(
                        "Every \(distanceAlertCustomValue) \(units.distanceUnit)",
                        value: $distanceAlertCustomValue,
                        in: DistanceAlert.customRange
                    )
                }
            } header: {
                Text("Apple Watch")
            } footer: {
                Text("Taps your wrist as you pass each distance, like the Workout app does on a plain run. Loopback does this by dividing the run into shorter steps, so your watch counts them (3 of 8) and shows each as its own interval afterwards. Works for steps set by distance, not by time, and not during warmup or cooldown.")
            }

            Section {
                Picker("Distance and pace", selection: $units) {
                    ForEach(DisplayUnits.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            } header: {
                Text("Units")
            } footer: {
                Text("How distances and paces are shown here and on your dashboard, and the units your coach uses. Workouts on your watch and data on your server are unaffected.")
            }
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle("Training")
        .navigationBarTitleDisplayMode(.inline)
        // Runs already on the watch are rebuilt. The pause lets a few taps
        // on the stepper settle first.
        .task(id: distanceAlertSetting) {
            guard let applied = appliedDistanceAlertSetting else {
                appliedDistanceAlertSetting = distanceAlertSetting
                return
            }
            guard applied != distanceAlertSetting else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await applyDistanceAlertSetting()
        }
        // Leaving within that pause cancels it; the change still counts.
        .onDisappear {
            Task { await applyDistanceAlertSetting() }
        }
        .alert("Calendar access is off", isPresented: $showingCalendarAccessAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Loopback full access to Calendar in iOS Settings, then switch this on again.")
        }
    }

    /// Everything the alert distance depends on. Units count only for the
    /// custom distance.
    private var distanceAlertSetting: String {
        switch distanceAlert {
        case .off, .kilometer, .mile: distanceAlert.rawValue
        case .custom: "\(distanceAlertCustomValue) \(units.distanceUnit)"
        }
    }

    private func applyDistanceAlertSetting() async {
        guard let applied = appliedDistanceAlertSetting, applied != distanceAlertSetting else { return }
        appliedDistanceAlertSetting = distanceAlertSetting
        await scheduleManager.reapplyDistanceAlerts()
    }

    /// On only while iOS still grants access: if that was revoked in iOS
    /// Settings, nothing is being written and the switch shouldn't claim so.
    private var calendarSyncBinding: Binding<Bool> {
        Binding(
            get: { calendarSyncEnabled && CalendarSync.hasAccess },
            set: { wantsOn in
                Task {
                    if wantsOn {
                        guard await CalendarSync.shared.requestAccess() else {
                            showingCalendarAccessAlert = true
                            return
                        }
                        calendarSyncEnabled = true
                        await scheduleManager.syncCalendar()
                    } else {
                        calendarSyncEnabled = false
                        await CalendarSync.shared.removeCalendar()
                    }
                }
            }
        )
    }
}
