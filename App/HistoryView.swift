import SwiftUI
import Charts

/// Tagesverlauf aus dem lokalen Speicher.
struct HistoryView: View {
    @State private var tage: [DayTotals] = []
    @State private var bestand: (anzahl: Int, seit: Date?) = (0, nil)
    @State private var reihe: Reihe = .erzeugung
    @State private var aufloesung: Resolution = .day
    @State private var zeitraum: Zeitraum = .automatisch

    /// Wie weit zurück angezeigt wird. „Automatisch" nimmt den zur Auflösung
    /// passenden Vorschlag.
    enum Zeitraum: String, CaseIterable, Identifiable {
        case automatisch = "Automatisch"
        case tag = "24 Stunden"
        case woche = "7 Tage"
        case monat = "30 Tage"
        case jahr = "1 Jahr"
        var id: String { rawValue }

        func span(_ r: Resolution) -> TimeInterval? {
            switch self {
            case .automatisch: return nil
            case .tag:   return 24 * 3600
            case .woche: return 7 * 24 * 3600
            case .monat: return 30 * 24 * 3600
            case .jahr:  return 365 * 24 * 3600
            }
        }
    }

    enum Reihe: String, CaseIterable, Identifiable {
        case erzeugung = "Erzeugung"
        case verbrauch = "Verbrauch"
        case einspeisung = "Einspeisung"
        case bezug = "Netzbezug"
        var id: String { rawValue }

        var farbe: Color {
            switch self {
            case .erzeugung:   return Color(red: 0.98, green: 0.72, blue: 0.11)
            case .verbrauch:   return Color(red: 0.35, green: 0.62, blue: 1.0)
            case .einspeisung: return Color(red: 0.20, green: 0.82, blue: 0.45)
            case .bezug:       return Color(red: 1.0, green: 0.35, blue: 0.32)
            }
        }

        func wert(_ t: DayTotals) -> Int {
            switch self {
            case .erzeugung:   return t.production
            case .verbrauch:   return t.consumption
            case .einspeisung: return t.gridSell
            case .bezug:       return t.gridBuy
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            kopf

            HStack(spacing: 12) {
                Picker("Auflösung", selection: $aufloesung) {
                    ForEach(Resolution.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 200)
                Picker("Zeitraum", selection: $zeitraum) {
                    ForEach(Zeitraum.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 210)
                Spacer()
            }
            .onChange(of: aufloesung) { _, _ in laden() }
            .onChange(of: zeitraum) { _, _ in laden() }

            if tage.isEmpty {
                leer
            } else {
                Picker("", selection: $reihe) {
                    ForEach(Reihe.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                diagramm
                tabelle
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
        .onAppear(perform: laden)
    }

    private var kopf: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Verlauf")
                .font(.system(size: 20, weight: .semibold))
            Spacer()
            if let seit = bestand.seit {
                Text("\(bestand.anzahl) Messpunkte seit \(seit.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Aktualisieren", action: laden)
        }
    }

    private var leer: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Noch keine Daten")
                .font(.headline)
            Text("Der Verlauf wird aufgebaut, solange die App läuft. Die erste Tagesbilanz erscheint, sobald Messpunkte über mehrere Stunden vorliegen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var diagramm: some View {
        Chart(tage) { punkt in
            BarMark(
                x: .value("Zeit", punkt.date, unit: aufloesung.chartUnit),
                y: .value("kWh", Double(reihe.wert(punkt)) / 1000)
            )
            .foregroundStyle(reihe.farbe.gradient)
            .cornerRadius(3)
        }
        .chartXAxis {
            AxisMarks(preset: .aligned) { wert in
                AxisGridLine()
                AxisValueLabel(format: achsenformat)
            }
        }
        .chartYAxis {
            AxisMarks { wert in
                AxisGridLine()
                AxisValueLabel {
                    if let v = wert.as(Double.self) {
                        Text(v < 1 ? "\(Int(v * 1000)) Wh" : "\(v, specifier: "%.1f") kWh")
                    }
                }
            }
        }
        .frame(height: 210)
    }

    private var achsenformat: Date.FormatStyle {
        switch aufloesung {
        case .fiveMinutes, .quarter: return .dateTime.hour().minute()
        case .hour:                  return .dateTime.day(.twoDigits).hour()
        case .day:                   return .dateTime.day().month(.abbreviated)
        case .month:                 return .dateTime.month(.abbreviated).year(.twoDigits)
        }
    }

    private var tabelle: some View {
        ScrollView {
            VStack(spacing: 0) {
                kopfzeile
                ForEach(tage.reversed()) { tag in
                    Divider()
                    zeile(tag)
                }
            }
        }
    }

    private var kopfzeile: some View {
        HStack(spacing: 0) {
            Text(aufloesung == .month ? "Monat" : (aufloesung == .day ? "Tag" : "Zeit"))
                .frame(width: 110, alignment: .leading)
            spalte("Erzeugung")
            spalte("Verbrauch")
            spalte("Einspeisung")
            spalte("Bezug")
            spalte("Autarkie")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func zeile(_ tag: DayTotals) -> some View {
        HStack(spacing: 0) {
            Text(tag.date.formatted(zeilenformat))
                .frame(width: 110, alignment: .leading)
            wert(tag.production)
            wert(tag.consumption)
            wert(tag.gridSell)
            wert(tag.gridBuy)
            Text("\(Int(tag.autarky * 100)) %")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .monospacedDigit()
        }
        .font(.system(size: 12))
        .padding(.vertical, 5)
    }

    private var zeilenformat: Date.FormatStyle {
        switch aufloesung {
        case .fiveMinutes, .quarter: return .dateTime.day(.twoDigits).month(.twoDigits).hour().minute()
        case .hour:                  return .dateTime.day(.twoDigits).month(.twoDigits).hour()
        case .day:                   return .dateTime.weekday(.abbreviated).day().month(.twoDigits)
        case .month:                 return .dateTime.month(.wide).year()
        }
    }

    private func spalte(_ titel: String) -> some View {
        Text(titel).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func wert(_ wh: Int) -> some View {
        Text("\(wh.kilowattHourText) kWh")
            .frame(maxWidth: .infinity, alignment: .trailing)
            .monospacedDigit()
    }

    private func laden() {
        tage = HistoryStore.shared.bilanzen(resolution: aufloesung,
                                            span: zeitraum.span(aufloesung))
        bestand = HistoryStore.shared.bestand()
    }
}
