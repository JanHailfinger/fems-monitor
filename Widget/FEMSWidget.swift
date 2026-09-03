import WidgetKit
import SwiftUI

struct FEMSEntry: TimelineEntry {
    let date: Date
    let snapshot: FEMSSnapshot
}

struct FEMSProvider: TimelineProvider {
    /// WidgetKit reicht die Callbacks als `sending` herein; die Box trägt sie
    /// unverändert in den Task hinüber.
    private struct Callback<T>: @unchecked Sendable {
        let run: (T) -> Void
    }

    func placeholder(in context: Context) -> FEMSEntry {
        FEMSEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (FEMSEntry) -> Void) {
        if context.isPreview {
            completion(FEMSEntry(date: .now, snapshot: .placeholder))
            return
        }
        let callback = Callback(run: completion)
        Task {
            let snapshot: FEMSSnapshot
            if let gespeichert = SnapshotCache.laden() {
                snapshot = gespeichert
            } else {
                snapshot = await FEMSClient.fetch()
            }
            callback.run(FEMSEntry(date: snapshot.date, snapshot: snapshot))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FEMSEntry>) -> Void) {
        let callback = Callback(run: completion)
        Task {
            // Zuerst der Messwert der App; nur wenn der fehlt oder veraltet
            // ist, fragt das Widget selbst bei der Anlage nach.
            let snapshot: FEMSSnapshot
            if let gespeichert = SnapshotCache.laden() {
                snapshot = gespeichert
            } else {
                snapshot = await FEMSClient.fetch()
            }
            let entry = FEMSEntry(date: snapshot.date, snapshot: snapshot)
            // Bei Störung häufiger nachsehen als im Normalbetrieb
            let gewuenscht = TimeInterval(FEMSConfig.widgetInterval * 60)
            let interval: TimeInterval = snapshot.reachable
                ? gewuenscht
                : min(gewuenscht, 120)
            callback.run(Timeline(entries: [entry],
                                  policy: .after(.now.addingTimeInterval(interval))))
        }
    }
}

// MARK: - Ansichten

struct FEMSWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FEMSEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall:  SmallView(snapshot: entry.snapshot)
            case .systemLarge:  LargeView(entry: entry)
            default:            MediumView(entry: entry)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

private struct SmallView: View {
    let snapshot: FEMSSnapshot

    var body: some View {
        if !snapshot.reachable {
            OfflineView(compact: true)
        } else {
            VStack(spacing: 4) {
                EnergyRingView(snapshot: snapshot, lineWidth: 8, showLabels: false)

                HStack(spacing: 0) {
                    Kennzahl(symbol: "sun.max.fill",
                             wert: snapshot.production,
                             farbe: snapshot.color(for: .production))
                    Kennzahl(symbol: "house.fill",
                             wert: snapshot.consumption,
                             farbe: snapshot.color(for: .consumption))
                    Kennzahl(symbol: "powerplug.fill",
                             wert: snapshot.grid,
                             farbe: snapshot.color(for: .grid))
                }
            }
        }
    }
}

/// Symbol über Wert, für die kleine Widgetgröße.
private struct Kennzahl: View {
    let symbol: String
    let wert: Int
    let farbe: Color

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(farbe)
            Text(wert.powerValue)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(wert.powerUnit)
                .font(.system(size: 7))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MediumView: View {
    let entry: FEMSEntry

    var body: some View {
        if !entry.snapshot.reachable {
            OfflineView(compact: false)
        } else {
            HStack(spacing: 14) {
                EnergyRingView(snapshot: entry.snapshot, lineWidth: 10, showLabels: false)
                    .frame(width: 124)

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(FlowKind.allCases.enumerated()), id: \.offset) { _, kind in
                        FlowRow(kind: kind, snapshot: entry.snapshot)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if entry.snapshot.state >= 2 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(entry.snapshot.state == 3 ? .red : .orange)
                        }
                        Text(entry.date, style: .time)
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct LargeView: View {
    let entry: FEMSEntry

    var body: some View {
        if !entry.snapshot.reachable {
            OfflineView(compact: false)
        } else {
            VStack(spacing: 6) {
                EnergyRingView(snapshot: entry.snapshot, lineWidth: 11, showLabels: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                HStack(spacing: 5) {
                    if entry.snapshot.state >= 2 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(entry.snapshot.state == 3 ? .red : .orange)
                    }
                    Text(statusText)
                    Spacer()
                    Text(entry.date, style: .time)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusText: String {
        let g = entry.snapshot.grid
        if g > 5 { return "Netzbezug" }
        if g < -5 { return "Einspeisung" }
        return "Netz neutral"
    }
}

private struct FlowRow: View {
    let kind: FlowKind
    let snapshot: FEMSSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(snapshot.color(for: kind))
                .frame(width: 14)
            Text(kind.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(snapshot.power(for: kind).powerText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

private struct OfflineView: View {
    let compact: Bool

    /// Sagt, ob überhaupt ein Messwert vorliegt und wie alt er ist.
    private var hinweis: String {
        if let alter = SnapshotCache.alter() {
            return "letzter Wert vor \(Int(alter / 60)) min\n\(FEMSConfig.host)"
        }
        return "App starten\n\(FEMSConfig.host)"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: compact ? 20 : 24))
                .foregroundStyle(.secondary)
            Text("Keine Daten")
                .font(.system(size: compact ? 10 : 12, weight: .medium))
                .multilineTextAlignment(.center)
            if !compact {
                Text(hinweis)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget

@main
struct FEMSWidget: Widget {
    let kind = "de.hailfinger.FEMSMonitor.EnergyFlow"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FEMSProvider()) { entry in
            FEMSWidgetView(entry: entry)
        }
        .configurationDisplayName("Energiefluss")
        .description("PV-Erzeugung, Verbrauch, Netz und Speicher der FENECON-Anlage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
