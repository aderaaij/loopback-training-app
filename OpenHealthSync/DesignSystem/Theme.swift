import SwiftUI
import UIKit

// MARK: - Loopback Design System
//
// A warm-black, self-hosted-training aesthetic. Dark only.
// Colors come straight from the Loopback design (Loopback.dc.html):
// background #0C0A09, cream text #F2ECE0, configurable accent.
//
// Three bundled faces: Space Grotesk for headings, Hanken Grotesk for text,
// JetBrains Mono for every number and date.
//
// Corners, spacing and type sizes are small closed sets (`LB.Radius`,
// `LB.Space`, the `LB…Size` enums). Pick by role; a number typed in at a call
// site is how fifteen radii and thirty-four font sizes got in last time.

enum LB {

    // MARK: Surfaces & background
    static let bg          = Color(hex: 0x0C0A09)   // app background
    static let surface     = Color(hex: 0x131009)   // standard card
    static let surfaceAlt   = Color(hex: 0x15110B)   // sheet / inner card
    static let surfaceControl = Color(hex: 0x16130E) // circular controls, segmented bg
    static let surfaceSunken = Color(hex: 0x0F0D08)  // route / chart cards
    static let surfaceTile   = Color(hex: 0x211C15)   // icon tiles, inactive pills
    static let heroTop       = Color(hex: 0x1B1610)   // plan hero gradient top
    static let heroBottom    = Color(hex: 0x130F09)   // plan hero gradient bottom
    static let trackEmpty    = Color(hex: 0x2A2520)   // empty segmented-progress track
    static let optionOff     = Color(hex: 0x1A150F)   // sheet option (unselected)

    // MARK: Text
    static let textPrimary   = Color(hex: 0xF2ECE0)   // cream
    static let textBright    = Color(hex: 0xC9C1B4)   // bright secondary
    static let textSecondary = Color(hex: 0x9A9286)
    static let textTertiary  = Color(hex: 0x8A8276)
    static let textMuted     = Color(hex: 0x5A5246)
    static let textFaint     = Color(hex: 0x4A4036)

    // MARK: Accent (configurable — single source of truth)
    static let accent        = Color(hex: 0xFF6A3D)   // orange, the design's working accent

    // MARK: Semantic
    static let green  = Color(hex: 0x5FB98A)   // done / good
    static let blue   = Color(hex: 0x6E91FF)   // upcoming / synced
    static let amber  = Color(hex: 0xE8A33D)   // missed / warning
    static let red    = Color(hex: 0xDC4A3B)   // hard effort
    static let violet = Color(hex: 0xA78BFA)   // strength / Hevy sessions

    // MARK: Heart-rate zones
    static let zone1 = Color(hex: 0x5E7C8E)
    static let zone2 = Color(hex: 0x5FA88A)
    static let zone3 = Color(hex: 0xD9A93E)
    static let zone4 = Color(hex: 0xEE7B3C)
    static let zone5 = Color(hex: 0xDC4A3B)

    // MARK: Hairlines / borders (cream at low alpha)
    static let line      = Color(hex: 0xF5EBDC).opacity(0.07)
    static let lineSoft  = Color(hex: 0xF5EBDC).opacity(0.045)
    static let lineStrong = Color(hex: 0xF5EBDC).opacity(0.12)

    // MARK: Radii
    //
    // Four steps and nothing in between. Pick by role, not by number: a new
    // shape is a card, something inside a card, a chip or a bar. Full
    // capsules are left to the system's glass controls and to toggles.
    enum Radius {
        /// Cards, stat tiles, the plan hero.
        static let card: CGFloat = 12
        /// Anything that sits inside a card: rows, day cells, maps, pills,
        /// buttons, icon tiles.
        static let inner: CGFloat = 8
        /// Status chips.
        static let chip: CGFloat = 4
        /// Progress segments, chart bars, legend swatches.
        static let bar: CGFloat = 2
    }

    // MARK: Spacing
    //
    // A 4pt grid. The screen edge and the inside of a card are both `lg`, so
    // text in a card lines up one step in from text on the background.
    enum Space {
        /// Hairline gaps inside a drawing, such as between chart segments.
        static let xxs: CGFloat = 2
        /// A label and its value; a title and its subtitle.
        static let xs: CGFloat = 4
        /// A header and its content; an icon and its label; pills in a row.
        static let sm: CGFloat = 8
        /// Sibling cards; rows inside a card.
        static let md: CGFloat = 12
        /// The screen edge and card padding.
        static let lg: CGFloat = 16
        /// Between sections.
        static let xl: CGFloat = 24
        /// Between regions of a page, and around centred text.
        static let xxl: CGFloat = 32
        /// The plan hero's inset, which leaves room for its corner ticks.
        static let heroInset: CGFloat = 20
    }

    /// Accent at a given mix-with-transparent alpha (mirrors color-mix in the design).
    static func accentTint(_ alpha: Double = 0.16) -> Color { accent.opacity(alpha) }

    // UIKit bridges
    static let uiBg = UIColor(bg)
    static let uiCream = UIColor(textPrimary)
    static let uiAccent = UIColor(accent)
    static let uiTertiary = UIColor(textTertiary)
}

// MARK: - Global UIKit appearance (warm-black nav + tab bars)

enum LBAppearance {
    static func apply() {
        LBFonts.register()

        // Navigation bars: cream titles on the system treatment. At rest the
        // bar is transparent so the warm-black screen shows through; once
        // content scrolls underneath, the default material takes over. An
        // opaque appearance here causes a dark cross-fade flash on push and
        // the large title failing to redraw after popping an inline screen.
        // Titles are set in the display face, like every other heading.
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: LB.uiCream,
            .font: UIFont(name: "SpaceGrotesk-SemiBold", size: LBDisplaySize.subheadline.rawValue)
                ?? .systemFont(ofSize: 17, weight: .semibold)
        ]
        let largeTitleAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: LB.uiCream,
            .font: UIFont(name: "SpaceGrotesk-Bold", size: LBDisplaySize.largeTitle.rawValue)
                ?? .systemFont(ofSize: 34, weight: .bold)
        ]

        let standard = UINavigationBarAppearance()
        standard.configureWithDefaultBackground()
        standard.titleTextAttributes = titleAttributes
        standard.largeTitleTextAttributes = largeTitleAttributes

        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.titleTextAttributes = titleAttributes
        edge.largeTitleTextAttributes = largeTitleAttributes

        UINavigationBar.appearance().standardAppearance = standard
        UINavigationBar.appearance().scrollEdgeAppearance = edge
        UINavigationBar.appearance().tintColor = LB.uiAccent

        // The tab bar keeps the system Liquid Glass treatment — an opaque
        // UITabBarAppearance here would flatten the floating bar. Selection
        // color comes from the app-level .tint(LB.accent).
    }
}

// MARK: - Screen / list helpers

extension View {
    /// Warm-black screen background that ignores safe area.
    func lbScreen() -> some View {
        self.background(LB.bg.ignoresSafeArea())
    }

    /// The one left and right margin every screen uses.
    func lbScreenEdge() -> some View {
        self.padding(.horizontal, LB.Space.lg)
    }

    /// Lines a navigation stack's large title up with `lbScreenEdge()`. Apply
    /// it to the root view of a stack whose title is large.
    func lbNavigationBarMargins() -> some View {
        self.background(LBNavigationBarMargins())
    }

    /// A list on the warm-black background whose sections are `LBSection`
    /// cards. Plain style, because the grouped style brings its own section
    /// fill and corner radius; the screen edge comes from the content margin.
    func lbList() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, LB.Space.lg, for: .scrollContent)
            .contentMargins(.top, LB.Space.sm, for: .scrollContent)
            // Low, so header, footer and spacer rows can be short. Card rows
            // set their own minimum.
            .environment(\.defaultMinListRowHeight, 1)
            .background(LB.bg.ignoresSafeArea())
    }
}

// MARK: - Navigation bar margins

/// The navigation bar's own side margin is 20 on the larger phones, which
/// sets a large title one step in from the cards below it. The margin is not
/// something an appearance proxy can set, so this reaches the bar it sits in.
private struct LBNavigationBarMargins: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ controller: Probe, context: Context) {}

    final class Probe: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        private func apply() {
            guard let navigationController else { return }
            navigationController.viewRespectsSystemMinimumLayoutMargins = false
            let bar = navigationController.navigationBar
            bar.preservesSuperviewLayoutMargins = false
            bar.insetsLayoutMarginsFromSafeArea = false
            bar.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 0, leading: LB.Space.lg, bottom: 0, trailing: LB.Space.lg
            )
        }
    }
}

// MARK: - Color from hex

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Typography
//
// Real bundled fonts: Space Grotesk (display), Hanken Grotesk (body),
// JetBrains Mono (numerics). Font.custom falls back to the system font
// automatically if a face fails to register, so these are always safe.

enum LBFonts {
    private static var registered = false

    static func register() {
        guard !registered else { return }
        registered = true
        var urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        urls += Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// The type scale: ten sizes across three families. Pick by role; a raw point
// size no longer compiles, which is what keeps 13 from drifting to 14.

/// Space Grotesk sizes.
enum LBDisplaySize: CGFloat {
    /// Screen titles.
    case largeTitle = 34
    /// The heading of a detail screen.
    case title = 26
    /// Card headings, the plan name, day numbers.
    case headline = 20
    /// Row titles and small headings.
    case subheadline = 16
}

/// Hanken Grotesk sizes.
enum LBBodySize: CGFloat {
    /// Sentences, buttons, text fields.
    case body = 15
    /// Subtitles, footnotes, section labels.
    case secondary = 13
    /// Tile labels, chips, weekday names.
    case caption = 11
}

/// JetBrains Mono sizes.
enum LBMonoSize: CGFloat {
    /// The big number on a tile or in the plan hero.
    case metric = 24
    /// Values in rows and tables.
    case value = 13
    /// Dates, metadata lines, axis labels.
    case caption = 11
}

extension Font {
    /// Display / headings — Space Grotesk. Pair with `.tracking(...)` for tight headers.
    static func lbDisplay(_ size: LBDisplaySize, _ weight: Font.Weight = .bold) -> Font {
        let face: String
        switch weight {
        case .black, .heavy, .bold: face = "SpaceGrotesk-Bold"
        case .semibold:             face = "SpaceGrotesk-SemiBold"
        case .medium:               face = "SpaceGrotesk-Medium"
        default:                    face = "SpaceGrotesk-Regular"
        }
        return .custom(face, fixedSize: size.rawValue)
    }

    /// Numerics, dates, codes — JetBrains Mono.
    static func lbMono(_ size: LBMonoSize, _ weight: Font.Weight = .medium) -> Font {
        let face: String
        switch weight {
        case .semibold, .bold, .heavy, .black: face = "JetBrainsMono-SemiBold"
        case .medium:                          face = "JetBrainsMono-Medium"
        default:                               face = "JetBrainsMono-Regular"
        }
        return .custom(face, fixedSize: size.rawValue)
    }

    /// Body / UI text — Hanken Grotesk.
    static func lbBody(_ size: LBBodySize, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .black, .heavy: face = "HankenGrotesk-ExtraBold"
        case .bold:          face = "HankenGrotesk-Bold"
        case .semibold:      face = "HankenGrotesk-SemiBold"
        case .medium:        face = "HankenGrotesk-Medium"
        default:             face = "HankenGrotesk-Regular"
        }
        return .custom(face, fixedSize: size.rawValue)
    }
}

// MARK: - Card surface

struct LBCard: ViewModifier {
    var fill: Color = LB.surface
    var radius: CGFloat = LB.Radius.card
    var border: Color = LB.line
    var borderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(border, lineWidth: borderWidth)
            )
    }
}

extension View {
    /// Standard Loopback surface card.
    func lbCard(fill: Color = LB.surface,
                radius: CGFloat = LB.Radius.card,
                border: Color = LB.line,
                borderWidth: CGFloat = 1) -> some View {
        modifier(LBCard(fill: fill, radius: radius, border: border, borderWidth: borderWidth))
    }
}

// MARK: - Section header (uppercase, tracked, tertiary)

struct LBSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.lbBody(.secondary, .bold))
            .tracking(0.6)
            .foregroundStyle(LB.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tile row (stats that share one card)

/// Two or three numbers that belong together, in one card split by hairlines.
/// A card each made them compete with the cards around them.
struct LBTileRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            Group(subviews: content) { tiles in
                ForEach(tiles.indices, id: \.self) { index in
                    if index > 0 {
                        Rectangle().fill(LB.line).frame(width: 1)
                    }
                    tiles[index]
                }
            }
        }
        // Without this the hairlines stretch to whatever height is on offer.
        .fixedSize(horizontal: false, vertical: true)
        .lbCard()
    }
}

// MARK: - Trend tile (big mono number over a tracked caption)

/// One number in an `LBTileRow` on the Trends screens — year mileage, average
/// intake, logging coverage. Sized to sit three-across on the narrowest
/// supported iPhone, which is why both labels scale down rather than wrap.
///
/// Distinct from `LBStatTile`, the left-aligned display-font tile the workout
/// detail screen uses; this is the centered mono variant.
struct LBTrendTile: View {
    let value: String
    let label: String
    var valueColor: Color = LB.textPrimary

    var body: some View {
        VStack(spacing: LB.Space.xs) {
            Text(value)
                .font(.lbMono(.metric, .semibold))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label.uppercased())
                .font(.lbBody(.caption, .semibold))
                .tracking(0.5)
                .foregroundStyle(LB.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, LB.Space.lg)
        .padding(.horizontal, LB.Space.sm)
    }
}

// MARK: - Status chip (DONE / SYNCED / PENDING / SKIPPED …)

struct LBStatusChip: View {
    let text: String
    var color: Color = LB.textSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.lbBody(.caption, .semibold))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, LB.Space.sm)
            .padding(.vertical, LB.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: LB.Radius.chip, style: .continuous)
                    .fill(color.opacity(0.14))
            )
    }
}

// MARK: - Circular icon button (top controls, back buttons)

struct LBCircleButton: View {
    let systemName: String
    var size: CGFloat = 42
    var iconColor: Color = LB.textBright
    var spinning: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(iconColor)
                .frame(width: size, height: size)
                .background(Circle().fill(LB.surfaceControl))
                .overlay(Circle().strokeBorder(LB.line, lineWidth: 1))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                           value: spinning)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Corner ticks (technical framing on the plan hero)

struct LBCornerTicks: View {
    var color: Color = LB.textPrimary.opacity(0.22)
    var inset: CGFloat = 11
    var length: CGFloat = 9
    var lineWidth: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                // top-left
                p.move(to: CGPoint(x: inset, y: inset + length)); p.addLine(to: CGPoint(x: inset, y: inset)); p.addLine(to: CGPoint(x: inset + length, y: inset))
                // top-right
                p.move(to: CGPoint(x: w - inset - length, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset)); p.addLine(to: CGPoint(x: w - inset, y: inset + length))
                // bottom-left
                p.move(to: CGPoint(x: inset, y: h - inset - length)); p.addLine(to: CGPoint(x: inset, y: h - inset)); p.addLine(to: CGPoint(x: inset + length, y: h - inset))
                // bottom-right
                p.move(to: CGPoint(x: w - inset - length, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset)); p.addLine(to: CGPoint(x: w - inset, y: h - inset - length))
            }
            .stroke(color, lineWidth: lineWidth)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Pill toggle for view-mode switching (calendar / list)

struct LBSegmentToggle<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, systemImage: String)]

    var body: some View {
        HStack(spacing: LB.Space.xs) {
            ForEach(options, id: \.value) { opt in
                let on = selection == opt.value
                Image(systemName: opt.systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(on ? LB.accent : LB.textTertiary)
                    .frame(width: 54, height: 34)
                    .background(Capsule().fill(on ? LB.accentTint() : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt.value }
            }
        }
        .padding(LB.Space.xs)
        .background(Capsule().fill(LB.surfaceControl))
        .overlay(Capsule().strokeBorder(LB.line, lineWidth: 1))
    }
}
