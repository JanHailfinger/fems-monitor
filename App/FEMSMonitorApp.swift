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

        Settings {
            SettingsView()
        }
    }
}

/// Pollt die Anlage im Hintergrund und stößt Widget-Aktualisierungen an.
@MainActor
final class LiveModel: ObservableObject {
    @Published var snapshot = FEMSSnapshot.placeholder
    private var task: Task<Void, Never>?

    init() { start() }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                let neu = await FEMSClient.fetch()
                await MainActor.run { self?.snapshot = neu }
                WidgetCenter.shared.reloadAllTimelines()
                try? await Task.sleep(for: .seconds(FEMSConfig.pollInterval))
            }
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
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 400)
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
