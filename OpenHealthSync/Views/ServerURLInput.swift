//
//  ServerURLInput.swift
//  OpenHealthSync
//
//  Server-address entry row: an http/https scheme dropdown next to a host
//  field, the pattern Audiobookshelf-style clients use so self-hosters never
//  have to type a scheme by hand. Pasting a full URL into the host field
//  moves its scheme into the dropdown.
//

import SwiftUI

enum ServerScheme: String, CaseIterable, Identifiable {
    case https
    case http

    var id: String { rawValue }
    var label: String { "\(rawValue)://" }

    /// Splits a stored/pasted URL string into scheme + remainder.
    /// Defaults to https when no scheme is present.
    static func split(_ urlString: String) -> (scheme: ServerScheme, host: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ServerScheme.allCases where trimmed.lowercased().hasPrefix(scheme.label) {
            return (scheme, String(trimmed.dropFirst(scheme.label.count)))
        }
        return (.https, trimmed)
    }

    /// Recombines dropdown + host field into the full URL string the API
    /// clients expect. Empty host yields an empty string so "field is empty"
    /// checks keep working.
    static func compose(_ scheme: ServerScheme, _ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "\(scheme.rawValue)://\(trimmed)"
    }
}

struct ServerURLInput: View {
    @Binding var scheme: ServerScheme
    @Binding var host: String

    var body: some View {
        HStack(spacing: LB.Space.sm) {
            Picker("Scheme", selection: $scheme) {
                ForEach(ServerScheme.allCases) { scheme in
                    Text(scheme.label).tag(scheme)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            TextField("server.example.com:8443", text: $host)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: host) { _, newValue in
                    // A pasted full URL claims the dropdown and leaves the host.
                    if newValue.lowercased().hasPrefix("http") {
                        let (pastedScheme, remainder) = ServerScheme.split(newValue)
                        if remainder != newValue {
                            scheme = pastedScheme
                            host = remainder
                        }
                    }
                }
        }
    }
}
