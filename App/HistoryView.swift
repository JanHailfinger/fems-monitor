import SwiftUI
import Charts

/// Tagesverlauf aus dem lokalen Speicher.
struct HistoryView: View {
    @State private var tage: [DayTotals] = []
    @State private var bestand: (anzahl: Int, seit: Date?) = (0, nil)
    @State private var reihe: Reihe = .erzeugung

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
        Chart(tage) { tag in
            BarMark(
                x: .value("Tag", tag.date, unit: .day),
                y: .value("kWh", Double(reihe.wert(tag)) / 1000)
            )
            .foregroundStyle(reihe.farbe.gradient)
            .cornerRadius(4)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { wert in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks { wert in
                AxisGridLine()
                AxisValueLabel {
                    if let v = wert.as(Double.self) {
                        Text("\(v, specifier: "%.0f") kWh")
                    }
                }
            }
        }
        .frame(height: 200)
    }

    private var tabelle: some View {
        ScrollView {
            VStack(spacing: 0) {
                kopfzeile
                ForEach(tage) { tag in
                    Divider()
                    zeile(tag)
                }
            }
        }
    }

    private var kopfzeile: some View {
        HStack(spacing: 0) {
            Text("Tag").frame(width: 90, alignment: .leading)
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
            Text(tag.date.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits)))
                .frame(width: 90, alignment: .leading)
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

    private func spalte(_ titel: String) -> some View {
        Text(titel).frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func wert(_ wh: Int) -> some View {
        Text("\(wh.kilowattHourText) kWh")
            .frame(maxWidth: .infinity, alignment: .trailing)
            .monospacedDigit()
    }

    private func laden() {
        tage = HistoryStore.shared.tagesbilanzen(tage: 30).reversed()
        bestand = HistoryStore.shared.bestand()
    }
}
