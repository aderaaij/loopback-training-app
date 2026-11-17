//
//  TrainingSettingsView.swift
//  OpenHealthSync
//
//  Training preferences: preferred run time, week start, the iOS Calendar
//  mirror and display units.
//

import SwiftUI

struct TrainingSettingsView: View {
    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault
    @AppStorage(CalendarSync.enabledKey) private var calendarSyncEnabled = false
    @State private var showingCalendarAccessAlert = false
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
        .alert("Calendar access is off", isPresented: $showingCalendarAccessAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow Loopback full access to Calendar in iOS Settings, then switch this on again.")
        }
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
