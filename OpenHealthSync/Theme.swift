import SwiftUI
import UIKit

// MARK: - Loopback Design System
//
// A warm-black, self-hosted-training aesthetic. Dark only.
// Colors come straight from the Loopback design (Loopback.dc.html):
// background #0C0A09, cream text #F2ECE0, configurable accent.
//
// Typography is mapped to system fonts: monospaced for all numerics/dates
// (the signature JetBrains-Mono trait), default for display + body.
// Swap these helpers for bundled Space Grotesk / Hanken Grotesk / JetBrains
// Mono later for pixel-fidelity — every call site already routes through here.

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
    static let rCard: CGFloat = 20
    static let rHero: CGFloat = 24
    static let rInner: CGFloat = 17
    static let rPill: CGFloat = 14

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

        // Navigation bars
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = LB.uiBg
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: LB.uiCream]
        nav.largeTitleTextAttributes = [
            .foregroundColor: LB.uiCream,
            .font: UIFont.systemFont(ofSize: 34, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = LB.uiAccent

        // Tab bar
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = LB.uiBg
        tab.shadowColor = .clear
        let item = tab.stackedLayoutAppearance
        item.selected.iconColor = LB.uiAccent
        item.selected.titleTextAttributes = [.foregroundColor: LB.uiAccent]
        item.normal.iconColor = LB.uiTertiary
        item.normal.titleTextAttributes = [.foregroundColor: LB.uiTertiary]
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = LB.uiAccent
    }
}

// MARK: - Screen / list helpers

extension View {
    /// Warm-black screen background that ignores safe area.
    func lbScreen() -> some View {
        self.background(LB.bg.ignoresSafeArea())
    }

    /// Hide the default grouped-list background and drop in the warm-black surface.
    func lbList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(LB.bg.ignoresSafeArea())
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

extension Font {
    /// Display / headings — Space Grotesk. Pair with `.tracking(...)` for tight headers.
    static func lbDisplay(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let face: String
        switch weight {
        case .black, .heavy, .bold: face = "SpaceGrotesk-Bold"
        case .semibold:             face = "SpaceGrotesk-SemiBold"
        case .medium:               face = "SpaceGrotesk-Medium"
        default:                    face = "SpaceGrotesk-Regular"
        }
        return .custom(face, fixedSize: size)
    }

    /// Numerics, dates, codes — JetBrains Mono.
    static func lbMono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        let face: String
        switch weight {
        case .semibold, .bold, .heavy, .black: face = "JetBrainsMono-SemiBold"
        case .medium:                          face = "JetBrainsMono-Medium"
        default:                               face = "JetBrainsMono-Regular"
        }
        return .custom(face, fixedSize: size)
    }

    /// Body / UI text — Hanken Grotesk.
    static func lbBody(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .black, .heavy: face = "HankenGrotesk-ExtraBold"
        case .bold:          face = "HankenGrotesk-Bold"
        case .semibold:      face = "HankenGrotesk-SemiBold"
        case .medium:        face = "HankenGrotesk-Medium"
        default:             face = "HankenGrotesk-Regular"
        }
        return .custom(face, fixedSize: size)
    }
}

// MARK: - Card surface

struct LBCard: ViewModifier {
    var fill: Color = LB.surface
    var radius: CGFloat = LB.rCard
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
                radius: CGFloat = LB.rCard,
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
            .font(.lbBody(13, .bold))
            .tracking(0.6)
            .foregroundStyle(LB.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Status chip (DONE / SYNCED / PENDING / SKIPPED …)

struct LBStatusChip: View {
    let text: String
    var color: Color = LB.textSecondary

    var body: some View {
        Text(text.uppercased())
            .font(.lbBody(10, .semibold))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        HStack(spacing: 3) {
            ForEach(options, id: \.value) { opt in
                let on = selection == opt.value
                Image(systemName: opt.systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(on ? LB.accent : LB.textTertiary)
                    .frame(width: 54, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(on ? LB.accentTint() : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt.value }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(LB.surfaceControl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(LB.line, lineWidth: 1)
        )
    }
}
