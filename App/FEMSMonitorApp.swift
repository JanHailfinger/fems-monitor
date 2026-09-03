import SwiftUI
import WidgetKit

@main
struct FEMSMonitorApp: App {
    @StateObject private var model = LiveModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
                .frame(width: 300)
        } label: {
            MenuLabel(snapshot: model.snapshot)
        }
        .menuBarExtraStyle(.window)

        Window("Verlauf", id: "history") {
            HistoryView()
        }
        .defaultSize(width: 700, height: 560)

        Settings {
            SettingsView()
        }
    }
}

/// Pollt die Anlage im Hintergrund und stößt Widget-Aktualisierungen an.
@MainActor
final class LiveModel: ObservableObject {
    @Published var snapshot = FEMSSnapshot.placeholder
    @Published var heatPump: HeatPumpState?
    @Published var heatPumpFehler: String?
    @Published var boost = BoostStatus()

    /// Gemessene Aufnahme der Wärmepumpe in Watt, sofern die Cloud sie liefert.
    var heatPumpWatt: Int? {
        guard let kw = heatPump?.powerConsumptionToday else { return nil }
        return Int(kw * 1000)
    }
    private var task: Task<Void, Never>?
    private var waermepumpeTask: Task<Void, Never>?
    private var letzteWaermepumpe: Date = .distantPast

    init() {
        start()
        starteWaermepumpe()
        Task { await FEMSClient.aktualisiereKapazitaet() }
    }

    /// Die Viessmann-Cloud begrenzt die Aufrufe pro Tag, daher deutlich
    /// seltener als die lokale FEMS-Abfrage.
    func starteWaermepumpe() {
        waermepumpeTask?.cancel()
        guard ViessmannConfig.isConnected else { return }
        waermepumpeTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let zustand = try await ViessmannClient.zustand()
                    await MainActor.run {
                        self?.heatPump = zustand
                        self?.heatPumpFehler = nil
                    }
                } catch {
                    await MainActor.run { self?.heatPumpFehler = error.localizedDescription }
                }
                try? await Task.sleep(for: .seconds(ViessmannConfig.pollMinutes * 60))
            }
        }
    }

    /// Zählerstände werden seltener geschrieben als die Momentanwerte geholt.
    private var letzterVerlaufspunkt: Date = .distantPast
    /// Messwerte der Speicherleistung für die geglättete Reichweite.
    private var speicherVerlauf: [(zeit: Date, watt: Int)] = []
    private let verlaufsabstand: TimeInterval = 300

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                var neu = await FEMSClient.fetch()
                // Speicherleistung über 10 Minuten glätten, damit die
                // Reichweite nicht bei jedem Lastsprung springt.
                if let self {
                    let jetzt = Date.now
                    self.speicherVerlauf.append((jetzt, neu.battery))
                    self.speicherVerlauf.removeAll { jetzt.timeIntervalSince($0.zeit) > 600 }
                    let werte = self.speicherVerlauf.map(\.watt)
                    if !werte.isEmpty {
                        neu.smoothedBattery = werte.reduce(0, +) / werte.count
                    }
                }
                SnapshotCache.speichern(neu)
                await MainActor.run { self?.snapshot = neu }
                WidgetCenter.shared.reloadAllTimelines()
                await self?.verlaufSchreiben(erreichbar: neu.reachable)
                if neu.reachable {
                    // Netzwert umgedreht: positiv = Einspeisung, negativ = Bezug
                    let netto = -neu.grid
                    let wp = await MainActor.run { self?.heatPumpWatt }
                    await HeatPumpBoost.shared.pruefe(netto: netto, waermepumpe: wp)
                    let stand = await HeatPumpBoost.shared.status
                    await MainActor.run { self?.boost = stand }
                }
                try? await Task.sleep(for: .seconds(FEMSConfig.pollInterval))
            }
        }
    }

    private func verlaufSchreiben(erreichbar: Bool) async {
        guard erreichbar, Date.now.timeIntervalSince(letzterVerlaufspunkt) >= verlaufsabstand
        else { return }
        letzterVerlaufspunkt = .now
        if let zaehler = await FEMSClient.fetchCounters() {
            HistoryStore.shared.speichern(zaehler)
        }
    }

    func refreshNow() {
        Task {
            snapshot = await FEMSClient.fetch()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// Kompakte Anzeige in der Menüleiste.
private struct MenuLabel: View {
    let snapshot: FEMSSnapshot

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(text)
        }
    }

    private var symbol: String {
        if !snapshot.reachable { return "bolt.slash" }
        if snapshot.production > 50 { return "sun.max.fill" }
        if !snapshot.batteryPresent { return "bolt.badge.questionmark" }
        switch snapshot.soc {
        case ..<13:  return "battery.0percent"
        case ..<38:  return "battery.25percent"
        case ..<63:  return "battery.50percent"
        case ..<88:  return "battery.75percent"
        default:     return "battery.100percent"
        }
    }

    private var text: String {
        if !snapshot.reachable { return "–" }
        if snapshot.production > 50 { return snapshot.production.powerText }
        if !snapshot.batteryPresent { return snapshot.grid.powerText }
        return "\(snapshot.soc) %"
    }
}

private struct MenuContent: View {
    @ObservedObject var model: LiveModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private func oeffneFenster(id: String) {
        openWindow(id: id)
    }

    private func oeffneEinstellungen() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }

    var body: some View {
        VStack(spacing: 10) {
            EnergyRingView(snapshot: model.snapshot, lineWidth: 11, showLabels: true, animated: true)
                .frame(height: 205)
                .padding(.top, 6)

            VStack(spacing: 6) {
                ForEach(Array(FlowKind.allCases.enumerated()), id: \.offset) { _, kind in
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbol)
                            .foregroundStyle(model.snapshot.color(for: kind))
                            .frame(width: 16)
                        Text(kind.label)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(model.snapshot.power(for: kind).powerText)
                            .monospacedDigit()
                            .fontWeight(.medium)
                    }
                    .font(.system(size: 12))
                }
            }

            if let r = model.snapshot.runtime, let text = model.snapshot.runtimeText {
                HStack(spacing: 6) {
                    Image(systemName: r.charging ? "battery.100.bolt" : "gauge.with.needle")
                        .foregroundStyle(r.charging ? .green : .secondary)
                    Text(r.charging ? "voll in" : "reicht noch")
                        .foregroundStyle(.secondary)
                    Text(text).fontWeight(.medium).monospacedDigit()
                    Spacer()
                    if let bis = model.snapshot.runtimeUntil {
                        Text(bis, style: .time)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 12))
            }

            if let wp = model.heatPump {
                Divider()
                WaermepumpeZeile(zustand: wp)
            }

            if BoostConfig.enabled {
                BoostZeile(status: model.boost)
            }

            if model.snapshot.state >= 2 {
                Label(model.snapshot.state == 3 ? "Störung" : "Warnung",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(model.snapshot.state == 3 ? .red : .orange)
            }

            Divider()

            VStack(spacing: 0) {
                MenuAction(titel: "Aktualisieren", symbol: "arrow.clockwise") {
                    model.refreshNow()
                }
                MenuAction(titel: "Verlauf …", symbol: "chart.bar") {
                    NSApp.activate(ignoringOtherApps: true)
                    oeffneFenster(id: "history")
                }
                MenuAction(titel: "Einstellungen …", symbol: "gearshape") {
                    oeffneEinstellungen()
                }
                MenuAction(titel: "FEMS-Monitoring öffnen", symbol: "safari") {
                    if let url = URL(string: "https://portal.fenecon.de") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider().padding(.vertical, 4)
                MenuAction(titel: "Beenden", symbol: "power") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(12)
    }
}

private struct SettingsView: View {
    @AppStorage("host", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var host = FEMSConfig.defaultHost
    @AppStorage("password", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var password = FEMSConfig.defaultPassword
    @AppStorage("pollInterval", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var pollInterval = FEMSConfig.defaultPollInterval
    @AppStorage("widgetInterval", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var widgetInterval = FEMSConfig.defaultWidgetInterval

    @AppStorage("viClientID", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var viClientID = ""
    @AppStorage("viPollMinutes", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var viPoll = 10

    @StateObject private var auth = ViessmannAuth()
    @AppStorage("boostEnabled", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostEnabled = false
    @AppStorage("boostThreshold", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostThreshold = 5000
    @AppStorage("boostHygiene", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostHygiene = true
    @AppStorage("boostAverage", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostAverage = 5
    @AppStorage("boostOffFactor", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostOffFactor = 0.7
    @AppStorage("boostDelay", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostDelay = 10
    @AppStorage("boostHold", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostHold = 30
    @AppStorage("boostTemp", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostTemp = 58
    @AppStorage("boostNormalTemp", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostNormalTemp = 52
    @AppStorage("boostStartHour", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostStartHour = 9
    @AppStorage("boostEndHour", store: UserDefaults(suiteName: FEMSConfig.suiteName))
    private var boostEndHour = 18
    @State private var pruefung: String?
    @State private var laeuft = false

    private let sekunden = [5, 10, 15, 30, 60, 120, 300]
    private let minuten = [5, 10, 15, 30, 60]

    var body: some View {
        Form {
            Section("Verbindung") {
                TextField("IP-Adresse", text: $host)
                SecureField("Passwort", text: $password)
                HStack {
                    Button("Verbindung testen") { teste() }
                        .disabled(laeuft)
                    if let pruefung {
                        Text(pruefung)
                            .font(.caption)
                            .foregroundStyle(pruefung.hasPrefix("Verbunden") ? .green : .red)
                    }
                }
            }

            Section("Aktualisierung") {
                Picker("Menüleiste", selection: $pollInterval) {
                    ForEach(sekunden, id: \.self) { s in
                        Text(s < 60 ? "alle \(s) s" : "alle \(s / 60) min").tag(s)
                    }
                }
                Picker("Widget", selection: $widgetInterval) {
                    ForEach(minuten, id: \.self) { m in
                        Text("alle \(m) min").tag(m)
                    }
                }
                Text("Solange die Menüleisten-App läuft, aktualisiert sie das Widget bei jeder eigenen Abfrage mit. Der Widget-Wert greift, wenn die App beendet ist — WidgetKit behandelt ihn als Wunsch und kann bei knappem Systembudget seltener laden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Standard-Gastzugang des FEMS: Benutzer „x\u{201C}, Passwort „user\u{201C} — ausschließlich lesend.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Section("Wärmepumpe (Viessmann)") {
                TextField("Client-ID", text: $viClientID)
                Picker("Abfrage", selection: $viPoll) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { Text("alle \($0) min").tag($0) }
                }
                HStack {
                    if ViessmannConfig.isConnected {
                        Button("Abmelden") { auth.abmelden() }
                        Text("verbunden").font(.caption).foregroundStyle(.green)
                    } else {
                        Button("Bei Viessmann anmelden") { auth.anmelden() }
                            .disabled(viClientID.isEmpty || auth.laeuft)
                    }
                    if let m = auth.meldung {
                        Text(m).font(.caption)
                            .foregroundStyle(m == "Verbunden" ? .green : .red)
                            .lineLimit(2)
                    }
                }
                Text("Client im Viessmann-Entwicklerportal anlegen und als Redirect-URI „http://localhost:4200/\u{201C} eintragen. Die Anmeldung öffnet sich im Systembrowser; die App nimmt nur den Rückruf auf Port 4200 entgegen und sieht dein Passwort nicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("PV-Überschuss in Wärme") {
                Toggle("Automatik aktiv", isOn: $boostEnabled)
                    .disabled(!ViessmannConfig.isConnected)

                LabeledContent("Schwelle") {
                    HStack {
                        Slider(value: .init(get: { Double(boostThreshold) },
                                            set: { boostThreshold = Int($0) }),
                               in: 500...8000, step: 250)
                        Text("\(boostThreshold) W").monospacedDigit().frame(width: 62, alignment: .trailing)
                    }
                }
                Picker("Mittelwert über", selection: $boostAverage) {
                    ForEach([2, 3, 5, 10, 15], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Ausschalten unter", selection: $boostOffFactor) {
                    ForEach([0.5, 0.6, 0.7, 0.8, 0.9], id: \.self) { f in
                        Text("\(Int(Double(boostThreshold) * f)) W").tag(f)
                    }
                }
                Picker("erst nach", selection: $boostDelay) {
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Mindestdauer", selection: $boostHold) {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) min").tag($0) }
                }
                Toggle("Hygienefunktion mitschalten (Volllast)", isOn: $boostHygiene)
                HStack {
                    Picker("Solltemperatur", selection: $boostTemp) {
                        ForEach(Array(stride(from: 50, through: 60, by: 1)), id: \.self) { Text("\($0) °C").tag($0) }
                    }
                    Picker("normal", selection: $boostNormalTemp) {
                        ForEach(Array(stride(from: 45, through: 55, by: 1)), id: \.self) { Text("\($0) °C").tag($0) }
                    }
                }
                HStack {
                    Picker("Zeitfenster", selection: $boostStartHour) {
                        ForEach(Array(0...23), id: \.self) { Text("\($0) Uhr").tag($0) }
                    }
                    Picker("bis", selection: $boostEndHour) {
                        ForEach(Array(1...24), id: \.self) { Text("\($0) Uhr").tag($0) }
                    }
                }
                Button("Solltemperatur jetzt zurücksetzen") {
                    Task { await HeatPumpBoost.shared.zuruecksetzen() }
                }
                .disabled(!ViessmannConfig.isConnected)

                Text("Liegt die Einspeisung länger als eingestellt über der Schwelle, hebt die App die Warmwasser-Solltemperatur an und schaltet die Hygienefunktion ein — das bringt den Verdichter auf Volllast, ohne den elektrischen Heizstab zu bemühen. Fällt die Einspeisung darunter, nimmt sie beides zurück. Geschrieben wird nur bei einem Zustandswechsel, höchstens acht Mal am Tag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 760)
        .onChange(of: host) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: password) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: widgetInterval) { _, _ in WidgetCenter.shared.reloadAllTimelines() }
    }

    private func teste() {
        laeuft = true
        pruefung = nil
        Task {
            let s = await FEMSClient.fetch()
            laeuft = false
            pruefung = s.reachable
                ? "Verbunden, \(s.batteryPresent ? "Ladezustand \(s.soc) %" : "Batterie getrennt")"
                : "Keine Antwort von \(host)"
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

/// Eine Zeile im Menüfenster, hebt sich beim Überfahren hervor.
private struct MenuAction: View {
    let titel: String
    let symbol: String
    let aktion: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: aktion) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(titel)
                    .font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hover ? Color.primary.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Kompakte Anzeige der Wärmepumpendaten aus der Viessmann-Cloud.
private struct WaermepumpeZeile: View {
    let zustand: HeatPumpState

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: zustand.compressorActive ? "heat.waves" : "thermometer.medium")
                    .foregroundStyle(zustand.compressorActive ? .orange : .secondary)
                Text("Wärmepumpe")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(zustand.compressorActive ? "läuft" : "aus")
                    .fontWeight(.medium)
            }
            .font(.system(size: 12))

            HStack(spacing: 10) {
                if let t = zustand.outsideTemperature {
                    wert("Außen", String(format: "%.1f °C", t))
                }
                if let t = zustand.supplyTemperature {
                    wert("Vorlauf", String(format: "%.1f °C", t))
                }
                if let t = zustand.hotWaterTemperature {
                    wert("Wasser", String(format: "%.0f °C", t))
                }
            }
        }
    }

    private func wert(_ titel: String, _ text: String) -> some View {
        VStack(spacing: 1) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(titel)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Zeigt, was die Überschussautomatik gerade tut.
private struct BoostZeile: View {
    let status: BoostStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(farbe)
            Text(status.phase.rawValue)
                .foregroundStyle(.secondary)
            Spacer()
            if status.messpunkte > 0 {
                Text(status.eigenlast > 0
                     ? "Ø \(status.mittelwert.powerText) (inkl. WP)"
                     : "Ø \(status.mittelwert.powerText)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if status.schaltungenHeute > 0 {
                Text("\(status.schaltungenHeute)×")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .font(.system(size: 11))
        .help(status.letzterFehler ?? "")
    }

    private var symbol: String {
        switch status.phase {
        case .aktiv:                 return "flame.fill"
        case .ueberschussErkannt:    return "hourglass"
        case .limitErreicht:         return "exclamationmark.circle"
        case .ausserhalbZeitfenster: return "moon"
        default:                     return "sun.max"
        }
    }

    private var farbe: Color {
        switch status.phase {
        case .aktiv:          return .orange
        case .limitErreicht:  return .red
        default:              return .secondary
        }
    }
}
