//
//  TrainingSettingsView.swift
//  OpenHealthSync
//
//  Training preferences: preferred run time, week start and display units.
//

import SwiftUI

struct TrainingSettingsView: View {
    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true
    @AppStorage(DisplayUnits.storageKey) private var units: DisplayUnits = .deviceDefault

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

            Section("Calendar") {
                Picker("Week starts on", selection: $weekStartsOnMonday) {
                    Text("Monday").tag(true)
                    Text("Sunday").tag(false)
                }
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
    }
}
