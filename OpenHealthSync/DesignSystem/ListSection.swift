import SwiftUI

// MARK: - List sections (Loopback)
//
// The system's grouped list draws each section with its own fill and its own
// corner radius, and offers no way to change the radius. So lists here are
// plain, and `LBSection` draws the card: one surface per section, hairlines
// between rows, the same corners as every other card.
//
// Use `LBSection` wherever a `List` or `Form` that ends in `.lbList()` would
// use `Section`.

struct LBSection<Content: View, Header: View, Footer: View>: View {
    private let bare: Bool
    private let gap: CGFloat
    private let content: Content
    private let header: Header
    private let footer: Footer

    /// - Parameters:
    ///   - bare: The rows draw their own surfaces (cards, a logo, an empty
    ///     state), so the section adds no card behind them.
    ///   - gap: The space after the section. A section gap by default; pass
    ///     `LB.Space.md` between cards that belong together.
    init(bare: Bool = false,
         gap: CGFloat = LB.Space.xl,
         @ViewBuilder content: () -> Content,
         @ViewBuilder header: () -> Header,
         @ViewBuilder footer: () -> Footer) {
        self.bare = bare
        self.gap = gap
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        // Header and footer are ordinary rows. A plain list pins a real
        // section header to the top while its rows scroll underneath.
        if Header.self != EmptyView.self {
            header
                .font(.lbBody(.secondary, .bold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(LB.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .lbUnstyledRow(bottom: LB.Space.sm)
        }

        if bare {
            content.listRowSeparator(.hidden)
        } else {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    rows[index]
                        // Pickers and plain labels take the body face too.
                        .font(.lbBody(.body))
                        .frame(minHeight: 20)
                        .listRowInsets(EdgeInsets(top: LB.Space.md, leading: LB.Space.lg,
                                                  bottom: LB.Space.md, trailing: LB.Space.lg))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            LBRowSurface(isFirst: index == rows.startIndex,
                                         isLast: index == rows.index(before: rows.endIndex))
                        )
                }
            }
        }

        if Footer.self != EmptyView.self {
            footer
                .font(.lbBody(.secondary))
                .foregroundStyle(LB.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lbUnstyledRow(top: LB.Space.sm)
        }

        // The gap to whatever follows.
        Color.clear
            .frame(height: gap)
            .lbUnstyledRow()
            .accessibilityHidden(true)
    }
}

extension LBSection where Header == EmptyView, Footer == EmptyView {
    init(bare: Bool = false, gap: CGFloat = LB.Space.xl, @ViewBuilder content: () -> Content) {
        self.init(bare: bare, gap: gap, content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension LBSection where Footer == EmptyView {
    init(bare: Bool = false, gap: CGFloat = LB.Space.xl,
         @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(bare: bare, gap: gap, content: content, header: header, footer: { EmptyView() })
    }
}

extension LBSection where Header == EmptyView {
    init(bare: Bool = false, gap: CGFloat = LB.Space.xl,
         @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(bare: bare, gap: gap, content: content, header: { EmptyView() }, footer: footer)
    }
}

extension LBSection where Header == Text, Footer == EmptyView {
    init(_ title: some StringProtocol, bare: Bool = false, gap: CGFloat = LB.Space.xl,
         @ViewBuilder content: () -> Content) {
        self.init(bare: bare, gap: gap, content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

// MARK: - Row surface

/// One row's share of a section card: the fill, the card's border along the
/// outside edges, and a hairline under every row but the last.
private struct LBRowSurface: View {
    let isFirst: Bool
    let isLast: Bool

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? LB.Radius.card : 0,
            bottomLeadingRadius: isLast ? LB.Radius.card : 0,
            bottomTrailingRadius: isLast ? LB.Radius.card : 0,
            topTrailingRadius: isFirst ? LB.Radius.card : 0,
            style: .continuous
        )
    }

    var body: some View {
        shape
            .fill(LB.surface)
            .overlay(
                // The border, minus the edges this row shares with a neighbour.
                shape
                    .strokeBorder(LB.line, lineWidth: 1)
                    .mask(
                        Rectangle()
                            .padding(.top, isFirst ? 0 : 1)
                            .padding(.bottom, isLast ? 0 : 1)
                    )
            )
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(LB.line)
                        .frame(height: 1)
                        .padding(.leading, LB.Space.lg)
                }
            }
    }
}

private extension View {
    /// A row with no surface, separator or inset of its own.
    func lbUnstyledRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        self
            .listRowInsets(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
