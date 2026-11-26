import SwiftUI

// MARK: - Card Modifiers (Loopback)
//
// Reskinned onto the Loopback warm-black surfaces. Every existing
// `.cardStyle()` / `.innerCardStyle()` call site picks these up for free.

/// Top-level containers (plan overview, day-detail wrapper, banners).
struct CardModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: LB.Radius.card, style: .continuous)
                    .fill(tint.map { $0.opacity(0.10) } ?? LB.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LB.Radius.card, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.28) } ?? LB.line, lineWidth: 1)
            )
    }
}

/// Individual items inside a container (workout rows, list items).
struct InnerCardModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                    .fill(tint.map { $0.opacity(0.10) } ?? LB.surfaceAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LB.Radius.inner, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.28) } ?? LB.line, lineWidth: 1)
            )
    }
}

extension View {
    func cardStyle(tint: Color? = nil) -> some View {
        modifier(CardModifier(tint: tint))
    }

    func innerCardStyle(tint: Color? = nil) -> some View {
        modifier(InnerCardModifier(tint: tint))
    }
}
