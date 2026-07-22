//
//  TrainingSettingsView.swift
//  OpenHealthSync
//
//  Training preferences: preferred run time and week start.
//

import SwiftUI

struct TrainingSettingsView: View {
    @AppStorage("preferredRunTime") private var preferredRunTime: String = PreferredRunTime.morning.rawValue
    @AppStorage("weekStartsOnMonday") private var weekStartsOnMonday: Bool = true

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
        }
        .listRowBackground(LB.surface)
        .lbList()
        .navigationTitle("Training")
        .navigationBarTitleDisplayMode(.inline)
    }
}
