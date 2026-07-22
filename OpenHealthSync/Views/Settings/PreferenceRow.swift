//
//  PreferenceRow.swift
//  OpenHealthSync
//
//  Settings hub row: tinted icon tile + title + optional subtitle.
//

import SwiftUI

struct PreferenceRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tint)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.lbDisplay(15, .semibold))
                    .foregroundStyle(LB.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    List {
        PreferenceRow(systemImage: "person.crop.circle", tint: LB.accent, title: "Account", subtitle: "arden@example.com")
        PreferenceRow(systemImage: "arrow.triangle.2.circlepath", tint: LB.blue, title: "Sync")
    }
    .lbList()
    .preferredColorScheme(.dark)
}
