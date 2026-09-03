import SwiftUI

/// Die vier Flussrichtungen im Ring, im Uhrzeigersinn ab oben.
enum FlowKind: CaseIterable {
    case production, consumption, battery, grid

    /// Mittelpunkt des Sektors in Grad, 0 = oben
    var center: Double {
        switch self {
        case .production: return 0
        case .consumption: return 90
        case .battery: return 180
        case .grid: return 270
        }
    }

    var span: Double { 74 }

    var symbol: String {
        switch self {
        case .production: return "sun.max.fill"
        case .consumption: return "house.fill"
        case .battery: return "battery.100"
        case .grid: return "powerplug.fill"
        }
    }

    var label: String {
        switch self {
        case .production: return "PV"
        case .consumption: return "Verbrauch"
        case .battery: return "Speicher"
        case .grid: return "Netz"
        }
    }
}

extension FEMSSnapshot {
    func power(for kind: FlowKind) -> Int {
        switch kind {
        case .production: return production
        case .consumption: return consumption
        case .battery: return battery
        case .grid: return grid
        }
    }

    func color(for kind: FlowKind) -> Color {
        switch kind {
        case .production: return Color(red: 0.98, green: 0.72, blue: 0.11)
        case .consumption: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .battery:     return Color(red: 0.20, green: 0.82, blue: 0.45)
        case .grid:
            if grid > 5  { return Color(red: 1.0, green: 0.35, blue: 0.32) }
            if grid < -5 { return Color(red: 0.20, green: 0.82, blue: 0.45) }
            return Color.gray
        }
    }

    /// Fließt Energie in diesem Sektor Richtung Haus (true) oder vom Haus weg?
    func inbound(_ kind: FlowKind) -> Bool {
        switch kind {
        case .production:  return true
        case .consumption: return false
        case .battery:     return battery > 0      // entladen speist ein
        case .grid:        return grid > 0         // Bezug kommt herein
        }
    }

    /// Bezugsgröße für die Segmentlänge, mindestens 500 W
    var scale: Double {
        let werte = FlowKind.allCases.map { Double(abs(power(for: $0))) }
        return max(500, werte.max() ?? 500)
    }

    var isActive: Bool {
        FlowKind.allCases.contains { abs(power(for: $0)) > 5 }
    }
}

/// Kreisbogen für ein Sektor-Segment.
struct RingArc: Shape {
    var center: Double
    var span: Double
    var inset: Double

    var animatableData: Double {
        get { span }
        set { span = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = max(1, min(rect.width, rect.height) / 2 - inset)
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: .degrees(center - span / 2 - 90),
            endAngle: .degrees(center + span / 2 - 90),
            clockwise: false
        )
        return path
    }
}

/// Der Energiefluss-Ring: vier Sektoren, Werte außen, Ladezustand in der Mitte.
struct EnergyRingView: View {
    let snapshot: FEMSSnapshot
    var lineWidth: Double = 14
    var showLabels: Bool = true
    /// Wandernde Punkte auf aktiven Sektoren — nur in der App, nicht im Widget.
    var animated: Bool = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            // Platzbedarf einer Beschriftung (halbe Ausdehnung) plus Luft
            let halbBreite = size < 200 ? 22.0 : 24.0
            let halbHoehe = size < 200 ? 12.0 : 14.0
            // Luft links und rechts der Beschriftung, damit sie beim
            // Zentrieren weder den Bogen noch den Rand berührt.
            let luft = 9.0

            // Eine Beschriftung braucht ihre volle Breite neben dem Bogen:
            // luft + 2 x halbe Ausdehnung, sonst ragt sie über den Bogen.
            let mitLabels = showLabels && size >= 190
            let radius: Double = mitLabels
                ? min(geo.size.width / 2 - 2 * halbBreite - 2 * luft - lineWidth / 2,
                      geo.size.height / 2 - 2 * halbHoehe - 2 * luft - lineWidth / 2)
                : size / 2 - lineWidth / 2 - size * 0.02
            let inset = size / 2 - radius

            ZStack {
                ForEach(Array(FlowKind.allCases.enumerated()), id: \.offset) { _, kind in
                    sector(kind: kind, inset: inset, size: size)
                }

                if animated {
                    FlowParticles(snapshot: snapshot, radius: radius, lineWidth: lineWidth)
                }

                centerReadout(size: radius * 2)

                if mitLabels {
                    ForEach(Array(FlowKind.allCases.enumerated()), id: \.offset) { _, kind in
                        FlowLabel(kind: kind, snapshot: snapshot, compact: size < 200)
                            .position(labelPosition(kind: kind, radius: radius, geo: geo,
                                                    abstand: luft,
                                                    halbBreite: halbBreite,
                                                    halbHoehe: halbHoehe))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sector(kind: FlowKind, inset: Double, size: Double) -> some View {
        let value = snapshot.power(for: kind)
        let fraction = min(1, Double(abs(value)) / snapshot.scale)
        let color = snapshot.color(for: kind)
        let aktiv = abs(value) > 5

        ZStack {
            RingArc(center: kind.center, span: kind.span, inset: inset)
                .stroke(Color.primary.opacity(0.08),
                        style: .init(lineWidth: lineWidth, lineCap: .round))

            RingArc(center: kind.center,
                    span: max(0.6, kind.span * (aktiv ? max(0.09, fraction) : 0.03)),
                    inset: inset)
                .stroke(
                    AngularGradient(
                        colors: [color.opacity(aktiv ? 0.55 : 0.18), color.opacity(aktiv ? 1 : 0.3)],
                        center: .center,
                        angle: .degrees(kind.center - 90)
                    ),
                    style: .init(lineWidth: lineWidth, lineCap: .round)
                )
                .shadow(color: aktiv ? color.opacity(0.45) : .clear, radius: 5)
                .animation(.smooth(duration: 0.6), value: fraction)
        }
    }

    private func centerReadout(size: Double) -> some View {
        VStack(spacing: size * 0.008) {
            if snapshot.batteryPresent {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(snapshot.soc)")
                        .font(.system(size: size * 0.20, weight: .light, design: .rounded))
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: size * 0.088, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "minus.plus.batteryblock.slash")
                    .font(.system(size: size * 0.15, weight: .light))
                    .foregroundStyle(.secondary)
            }

            // Reichweite wie beim Auto: wie lange der Speicher noch trägt
            if let text = snapshot.runtimeText {
                Text(text)
                    .font(.system(size: size * 0.082, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(snapshot.runtime?.charging == true ? .green : .primary)
                    .contentTransition(.numericText())
            }

            Text(snapshot.runtimeText != nil ? snapshot.runtimeLabel : batteryHint)
                .font(.system(size: size * 0.05, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
        }
        .animation(.smooth(duration: 0.5), value: snapshot.soc)
    }

    private var batteryHint: String {
        if !snapshot.batteryPresent { return "GETRENNT" }
        if snapshot.battery < -5 { return "LÄDT" }
        if snapshot.battery > 5 { return "ENTLÄDT" }
        return "SPEICHER"
    }

    private func labelPosition(kind: FlowKind, radius: Double, geo: GeometryProxy,
                               abstand: Double, halbBreite: Double,
                               halbHoehe: Double) -> CGPoint {
        // Mittig in den Streifen zwischen Bogenaußenkante und Rand setzen.
        let vertikal = kind == .production || kind == .battery
        let aussen = radius + lineWidth / 2
        let frei = vertikal
            ? geo.size.height / 2 - aussen
            : geo.size.width / 2 - aussen
        let r = aussen + frei / 2
        let rad = (kind.center - 90) * .pi / 180
        return CGPoint(x: geo.size.width / 2 + cos(rad) * r,
                       y: geo.size.height / 2 + sin(rad) * r)
    }
}

/// Wert plus Symbol an einem Sektor.
private struct FlowLabel: View {
    let kind: FlowKind
    let snapshot: FEMSSnapshot
    var compact: Bool = false

    var body: some View {
        let value = snapshot.power(for: kind)
        let aktiv = abs(value) > 5
        let color = snapshot.color(for: kind)

        VStack(spacing: 2) {
            Image(systemName: kind.symbol)
                .font(.system(size: compact ? 10 : 12, weight: .medium))
                .foregroundStyle(aktiv ? color : color.opacity(0.4))
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.powerValue)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(value.powerUnit)
                    .font(.system(size: compact ? 8 : 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(aktiv ? .primary : .secondary)
        }
        .fixedSize()
        .animation(.smooth(duration: 0.5), value: value)
    }
}

/// Punkte, die auf aktiven Sektoren in Flussrichtung wandern.
private struct FlowParticles: View {
    let snapshot: FEMSSnapshot
    let radius: Double
    let lineWidth: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)

                for kind in FlowKind.allCases {
                    let value = snapshot.power(for: kind)
                    guard abs(value) > 5 else { continue }

                    let color = snapshot.color(for: kind)
                    let fraction = min(1, Double(abs(value)) / snapshot.scale)
                    let arc = kind.span * max(0.09, fraction)
                    let speed = 0.22 + fraction * 0.5
                    let inbound = snapshot.inbound(kind)

                    for i in 0..<3 {
                        var t = (now * speed + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        if inbound { t = 1 - t }

                        let angle = kind.center - arc / 2 + arc * t - 90
                        let rad = angle * .pi / 180
                        let point = CGPoint(x: mid.x + cos(rad) * radius,
                                            y: mid.y + sin(rad) * radius)

                        // am Rand ein- und ausblenden
                        let fade = sin(t * .pi)
                        let r = lineWidth * 0.19
                        let rect = CGRect(x: point.x - r, y: point.y - r,
                                          width: r * 2, height: r * 2)
                        context.fill(Path(ellipseIn: rect),
                                     with: .color(.white.opacity(0.85 * fade)))
                    }
                }
            }
        }
    }
}
