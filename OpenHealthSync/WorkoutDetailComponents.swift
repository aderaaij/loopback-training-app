//
//  WorkoutDetailComponents.swift
//  OpenHealthSync
//
//  Loopback rich workout-detail building blocks: stat tile, effort gauge,
//  GPS route trace, heart-rate zone chart, and per-km splits.
//

import SwiftUI

// MARK: - Stat tile

struct LBStatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var accent: Bool = false
    /// When true the card fills the available height (used to align a stat
    /// grid with a taller neighbour such as the effort gauge).
    var stretch: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.lbBody(11))
                .tracking(0.2)
                .foregroundStyle(LB.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(value)
                    .font(.lbDisplay(24, .semibold))
                    .foregroundStyle(accent ? LB.accent : LB.textPrimary)
                if let unit {
                    Text(" \(unit)")
                        .font(.lbBody(13, .medium))
                        .foregroundStyle(LB.textMuted)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.45)
        }
        .frame(maxWidth: .infinity,
               maxHeight: stretch ? .infinity : nil,
               alignment: stretch ? .topLeading : .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 14)
        .lbCard(radius: 18)
    }
}

// MARK: - Section wrapper (uppercase header + trailing mono note + card)

struct LBDetailSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var fill: Color = LB.surface
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title.uppercased())
                    .font(.lbBody(13, .bold))
                    .tracking(0.4)
                    .foregroundStyle(LB.textTertiary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.lbMono(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }
            content
        }
        .padding(16)
        .lbCard(fill: fill)
    }
}

// MARK: - Effort gauge

/// Average heart-rate zone summary shown under the effort score.
struct LBEffortZone {
    let type: String     // "Aerobic" / "Anaerobic"
    let detail: String   // "Zone 2 · Easy"
    let color: Color
}

struct LBEffortGauge: View {
    /// RPE 1–10.
    let score: Double
    var estimated: Bool = false
    /// Average HR-zone summary, when heart-rate data is available.
    var zone: LBEffortZone? = nil

    private var fraction: CGFloat { CGFloat(min(max(score / 10, 0), 1)) }

    private var descriptor: (label: String, color: Color) {
        switch score {
        case ..<3.5:  return ("Easy", LB.green)
        case ..<5.5:  return ("Steady", LB.green)
        case ..<7:    return ("Moderate", LB.amber)
        case ..<8.5:  return ("Hard", LB.zone4)
        default:      return ("Max", LB.red)
        }
    }

    private var arcColor: Color { zone?.color ?? descriptor.color }

    private var scoreText: String {
        score == score.rounded() ? String(Int(score)) : String(format: "%.1f", score)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(LB.trackEmpty, lineWidth: 9)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(arcColor, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(scoreText)
                        .font(.lbDisplay(30, .bold))
                        .foregroundStyle(LB.textPrimary)
                    Text(estimated ? "EST · EFFORT" : "EFFORT")
                        .font(.lbBody(9))
                        .tracking(0.6)
                        .foregroundStyle(LB.textTertiary)
                }
            }
            .frame(width: 104, height: 104)

            VStack(spacing: 1) {
                if let zone {
                    Text(zone.type)
                        .font(.lbBody(12, .semibold))
                        .foregroundStyle(zone.color)
                    Text(zone.detail)
                        .font(.lbBody(11))
                        .foregroundStyle(LB.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(descriptor.label)
                        .font(.lbBody(12, .semibold))
                        .foregroundStyle(descriptor.color)
                    Text(estimated ? "Estimated · RPE" : "Rated · RPE")
                        .font(.lbBody(11))
                        .foregroundStyle(LB.textTertiary)
                }
            }
        }
        .frame(width: 128)
        .padding(14)
        .lbCard(radius: 18)
    }
}

// MARK: - Route trace

struct LBRouteMap: View {
    let route: [RoutePoint]

    var body: some View {
        GeometryReader { geo in
            let pts = mapped(in: geo.size)
            ZStack {
                gridPath(in: geo.size)
                    .stroke(LB.textPrimary.opacity(0.045), lineWidth: 1)
                if pts.count > 1 {
                    routePath(pts)
                        .stroke(LB.accent.opacity(0.30),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    routePath(pts)
                        .stroke(LB.accent,
                                style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    if let s = pts.first {
                        Circle().fill(LB.green)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(LB.surfaceSunken, lineWidth: 2))
                            .position(s)
                    }
                    if let e = pts.last {
                        Circle().fill(LB.accent)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(LB.surfaceSunken, lineWidth: 2))
                            .position(e)
                    }
                }
            }
        }
        .frame(height: 150)
    }

    private func gridPath(in size: CGSize) -> Path {
        var p = Path()
        let rows = 4, cols = 4
        for r in 1..<rows {
            let y = size.height * CGFloat(r) / CGFloat(rows)
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
        }
        for c in 1..<cols {
            let x = size.width * CGFloat(c) / CGFloat(cols)
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
        }
        return p
    }

    private func routePath(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        return p
    }

    private func mapped(in size: CGSize) -> [CGPoint] {
        guard route.count > 1 else { return [] }
        let lats = route.map(\.latitude), lons = route.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return [] }
        let midLat = (minLat + maxLat) / 2
        let cosMid = cos(midLat * .pi / 180)
        let pad: CGFloat = 14
        let w = size.width - 2 * pad, h = size.height - 2 * pad
        let latRange = max(maxLat - minLat, 1e-7)
        let lonRange = max((maxLon - minLon) * cosMid, 1e-7)
        let scale = min(w / CGFloat(latRange == 0 ? 1 : lonRange), h / CGFloat(latRange))
        let drawW = CGFloat(lonRange) * scale, drawH = CGFloat(latRange) * scale
        let ox = pad + (w - drawW) / 2, oy = pad + (h - drawH) / 2
        return route.map { pt in
            let x = ox + CGFloat((pt.longitude - minLon) * cosMid) * scale
            let y = oy + drawH - CGFloat(pt.latitude - minLat) * scale
            return CGPoint(x: x, y: y)
        }
    }
}

// MARK: - Heart-rate zone chart

struct LBHeartRateChart: View {
    let series: [TimeSeries]

    private struct Zone { let name: String; let lo: Double; let hi: Double; let color: Color }
    private let zones: [Zone] = [
        Zone(name: "Z1", lo: 0.50, hi: 0.60, color: LB.zone1),
        Zone(name: "Z2", lo: 0.60, hi: 0.70, color: LB.zone2),
        Zone(name: "Z3", lo: 0.70, hi: 0.80, color: LB.zone3),
        Zone(name: "Z4", lo: 0.80, hi: 0.90, color: LB.zone4),
        Zone(name: "Z5", lo: 0.90, hi: 1.05, color: LB.zone5),
    ]

    private var values: [Double] { series.map(\.value).filter { $0 > 0 } }
    private var yMax: Double { max((values.max() ?? 0) + 5, 1) }
    private var yMin: Double { max((values.min() ?? 0) - 5, 0) }
    private var maxHR: Double { max(values.max() ?? 0, 185) }
    private var span: Double { max(yMax - yMin, 1) }

    private func mapY(_ v: Double, _ h: CGFloat) -> CGFloat { h * (1 - CGFloat((v - yMin) / span)) }
    private func clampY(_ y: CGFloat, _ h: CGFloat) -> CGFloat { min(max(y, 0), h) }

    private func points(_ size: CGSize) -> [CGPoint] {
        let w = size.width, count = values.count
        guard count > 0 else { return [] }
        return values.enumerated().map { i, v in
            let x = count == 1 ? w / 2 : w * CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: x, y: mapY(v, size.height))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { geo in
                let pts = points(geo.size)
                ZStack {
                    ForEach(zones, id: \.name) { z in
                        zoneBand(z, in: geo.size)
                    }
                    if pts.count > 1 {
                        areaPath(pts, height: geo.size.height)
                            .fill(LB.accent.opacity(0.14))
                        linePath(pts)
                            .stroke(LB.accent,
                                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(height: 130)

            HStack(spacing: 14) {
                ForEach(zones, id: \.name) { z in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).fill(z.color).frame(width: 8, height: 8)
                        Text(z.name).font(.lbMono(10)).foregroundStyle(LB.textTertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func zoneBand(_ z: Zone, in size: CGSize) -> some View {
        let top = clampY(mapY(z.hi * maxHR, size.height), size.height)
        let bot = clampY(mapY(z.lo * maxHR, size.height), size.height)
        Rectangle()
            .fill(z.color.opacity(0.10))
            .frame(height: max(0, bot - top))
            .position(x: size.width / 2, y: (top + bot) / 2)
    }

    private func linePath(_ pts: [CGPoint]) -> Path {
        var p = Path(); p.addLines(pts); return p
    }

    private func areaPath(_ pts: [CGPoint], height: CGFloat) -> Path {
        var p = Path()
        guard let first = pts.first, let last = pts.last else { return p }
        p.move(to: CGPoint(x: first.x, y: height))
        p.addLines(pts)
        p.addLine(to: CGPoint(x: last.x, y: height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Splits

struct LBSplitsList: View {
    let splits: [Split]

    private var paces: [Double] { splits.map(\.pace).filter { $0 > 0 } }
    private var fastest: Double { paces.min() ?? 0 }
    private var slowest: Double { paces.max() ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(splits.enumerated()), id: \.offset) { i, split in
                row(i: i, split: split)
            }
        }
    }

    private func row(i: Int, split: Split) -> some View {
        let isFast = split.pace > 0 && split.pace == fastest
        let range = max(slowest - fastest, 1)
        let frac = slowest == fastest ? 1.0
            : 0.45 + (slowest - split.pace) / range * 0.55

        return HStack(spacing: 12) {
            Text(kmLabel(i: i, split: split))
                .font(.lbMono(12))
                .foregroundStyle(LB.textTertiary)
                .frame(width: 30, alignment: .leading)

            Text(paceText(split.pace))
                .font(.lbMono(13, .semibold))
                .foregroundStyle(isFast ? LB.accent : LB.textBright)
                .frame(width: 46, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LB.surfaceTile)
                    Capsule()
                        .fill(isFast ? LB.accent : LB.accent.opacity(0.45))
                        .frame(width: geo.size.width * CGFloat(min(max(frac, 0), 1)))
                }
            }
            .frame(height: 8)

            if let hr = split.averageHeartRate, hr > 0 {
                HStack(spacing: 0) {
                    Text("\(Int(hr))").foregroundStyle(LB.textSecondary)
                    Text(" bpm").foregroundStyle(LB.textMuted)
                }
                .font(.lbMono(12))
                .frame(width: 58, alignment: .trailing)
            } else {
                Spacer().frame(width: 58)
            }
        }
        .padding(.vertical, 7)
    }

    private func kmLabel(i: Int, split: Split) -> String {
        // Partial final split → show its distance in km; otherwise the km marker.
        if split.distance > 0 && split.distance < 950 {
            return String(format: "%.1f", split.distance / 1000)
        }
        return "\(i + 1)"
    }

    private func paceText(_ secPerKm: Double) -> String {
        guard secPerKm > 0 else { return "--" }
        let m = Int(secPerKm) / 60, s = Int(secPerKm) % 60
        return "\(m):\(String(format: "%02d", s))"
    }
}
