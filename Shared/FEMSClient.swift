import Foundation

/// Konfiguration der Anlage. Anpassbar in der App, Standardwerte hier.
enum FEMSConfig {
    /// Vorgabe für Adresse und Passwort.
    ///
    /// Die Widget-Extension kann bei ad-hoc signierten Builds nicht auf die
    /// gemeinsamen Einstellungen der App Group zugreifen und fällt deshalb
    /// auf diese Werte zurück. Wer das Widget nutzt, trägt hier seine eigene
    /// Adresse ein — die Einstellungen in der App wirken nur dort.
    static let defaultHost = "192.168.1.100"
    static let defaultPassword = "user"          // Standard-Gastzugang, nur lesend
    static let suiteName = "group.de.hailfinger.FEMSMonitor"

    static var host: String {
        UserDefaults(suiteName: suiteName)?.string(forKey: "host") ?? defaultHost
    }
    static var password: String {
        UserDefaults(suiteName: suiteName)?.string(forKey: "password") ?? defaultPassword
    }

    /// Nutzbare Speicherkapazität in Wattstunden. Wird beim Abruf aus
    /// `ess0/Capacity` übernommen, dient bis dahin als Vorgabe.
    static var capacityWh: Int {
        get {
            let w = UserDefaults(suiteName: suiteName)?.integer(forKey: "capacityWh") ?? 0
            return w > 0 ? w : 16800
        }
        set { UserDefaults(suiteName: suiteName)?.set(newValue, forKey: "capacityWh") }
    }

    /// Abfrageintervall der Menüleisten-App in Sekunden.
    static let defaultPollInterval = 30
    static var pollInterval: Int {
        let wert = UserDefaults(suiteName: suiteName)?.integer(forKey: "pollInterval") ?? 0
        return wert > 0 ? wert : defaultPollInterval
    }

    /// Abstand zweier Widget-Aktualisierungen in Minuten. WidgetKit behandelt
    /// den Wert als Wunsch — bei knappem Systembudget kann er länger ausfallen.
    static let defaultWidgetInterval = 5
    static var widgetInterval: Int {
        let wert = UserDefaults(suiteName: suiteName)?.integer(forKey: "widgetInterval") ?? 0
        return wert > 0 ? wert : defaultWidgetInterval
    }
}

/// Momentaufnahme der Anlagenwerte. Leistungen in Watt.
struct FEMSSnapshot: Sendable, Equatable, Codable {
    var production: Int = 0        // PV-Erzeugung, immer positiv
    var consumption: Int = 0       // Hausverbrauch
    var grid: Int = 0              // + Bezug, − Einspeisung
    var battery: Int = 0           // + entladen, − laden
    var soc: Int = 0               // Ladezustand in Prozent
    var state: Int = 0             // 0 Ok, 1 Info, 2 Warning, 3 Fault
    var batteryPresent: Bool = true
    /// Über einige Minuten geglättete Speicherleistung in Watt,
    /// positiv beim Entladen. Grundlage der Reichweitenanzeige.
    var smoothedBattery: Int = 0
    var date: Date = .now
    var reachable: Bool = true

    /// Verbleibende Zeit, bis der Speicher leer beziehungsweise voll ist.
    /// Nil, wenn er ruht oder keine Batterie vorhanden ist.
    var runtime: (hours: Double, charging: Bool)? {
        guard batteryPresent else { return nil }
        let leistung = smoothedBattery != 0 ? smoothedBattery : battery
        guard abs(leistung) > 60 else { return nil }
        let kapazitaet = Double(FEMSConfig.capacityWh)
        if leistung > 0 {
            // entlädt: bis leer
            let vorhanden = kapazitaet * Double(soc) / 100
            return (vorhanden / Double(leistung), false)
        } else {
            // lädt: bis voll
            let frei = kapazitaet * Double(100 - soc) / 100
            return (frei / Double(-leistung), true)
        }
    }

    static let placeholder = FEMSSnapshot(
        production: 3450, consumption: 820, grid: -1180,
        battery: -1450, soc: 74, state: 0
    )

    static func offline() -> FEMSSnapshot {
        var s = FEMSSnapshot()
        s.reachable = false
        return s
    }
}

/// Liest Datenpunkte über die REST/JSON-Schnittstelle des FEMS.
struct FEMSClient {
    private struct Channel: Decodable {
        let address: String
        let value: JSONValue?
    }

    /// Der value kann Zahl, String oder null sein.
    private enum JSONValue: Decodable {
        case int(Int), double(Double), string(String), null

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else if let v = try? c.decode(Double.self) { self = .double(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else { self = .null }
        }

        var intValue: Int {
            switch self {
            case .int(let v): return v
            case .double(let v): return Int(v.rounded())
            case .string(let v): return Int(v) ?? 0
            case .null: return 0
            }
        }
    }

    private static let channels = [
        "EssSoc", "EssDischargePower", "GridActivePower",
        "ProductionActivePower", "ConsumptionActivePower", "State"
    ]

    /// Liest die nutzbare Kapazität des Speichers und merkt sie sich.
    static func aktualisiereKapazitaet() async {
        guard let url = URL(string: "http://\(FEMSConfig.host)/rest/channel/ess0/Capacity")
        else { return }
        var request = URLRequest(url: url, timeoutInterval: 8)
        let token = Data("x:\(FEMSConfig.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let single = try? JSONDecoder().decode(Channel.self, from: data),
              let wert = single.value?.intValue, wert > 0
        else { return }
        FEMSConfig.capacityWh = wert
    }

    private static let energyChannels = [
        "ProductionActiveEnergy", "ConsumptionActiveEnergy",
        "GridBuyActiveEnergy", "GridSellActiveEnergy",
        "EssActiveChargeEnergy", "EssActiveDischargeEnergy", "EssSoc"
    ]

    /// Kumulierte Zählerstände für den Verlauf.
    static func fetchCounters() async -> EnergyCounters? {
        guard let values = await frage(energyChannels) else { return nil }
        return EnergyCounters(
            production: values["ProductionActiveEnergy"] ?? 0,
            consumption: values["ConsumptionActiveEnergy"] ?? 0,
            gridBuy: values["GridBuyActiveEnergy"] ?? 0,
            gridSell: values["GridSellActiveEnergy"] ?? 0,
            essCharge: values["EssActiveChargeEnergy"] ?? 0,
            essDischarge: values["EssActiveDischargeEnergy"] ?? 0,
            soc: values["EssSoc"] ?? 0
        )
    }

    /// Fragt eine Kanalgruppe in einem Aufruf ab.
    private static func frage(_ kanaele: [String]) async -> [String: Int]? {
        let pattern = "(" + kanaele.joined(separator: "|") + ")"
        guard let encoded = pattern.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "http://\(FEMSConfig.host)/rest/channel/_sum/\(encoded)")
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 8)
        let token = Data("x:\(FEMSConfig.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode([Channel].self, from: data)
            var values: [String: Int] = [:]
            for channel in decoded {
                let key = channel.address.split(separator: "/").last.map(String.init) ?? ""
                values[key] = channel.value?.intValue ?? 0
            }
            return values
        } catch {
            return nil
        }
    }

    static func fetch() async -> FEMSSnapshot {
        let pattern = "(" + channels.joined(separator: "|") + ")"
        guard let encoded = pattern.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "http://\(FEMSConfig.host)/rest/channel/_sum/\(encoded)")
        else { return .offline() }

        var request = URLRequest(url: url, timeoutInterval: 8)
        let credentials = "x:\(FEMSConfig.password)"
        let token = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200
            else { return .offline() }

            let decoded = try JSONDecoder().decode([Channel].self, from: data)
            var values: [String: Int] = [:]
            var socVorhanden = false
            for channel in decoded {
                let key = channel.address.split(separator: "/").last.map(String.init) ?? ""
                values[key] = channel.value?.intValue ?? 0
                if key == "EssSoc", let wert = channel.value, case .null = wert {} else if key == "EssSoc" {
                    socVorhanden = true
                }
            }

            return FEMSSnapshot(
                production: values["ProductionActivePower"] ?? 0,
                consumption: values["ConsumptionActivePower"] ?? 0,
                grid: values["GridActivePower"] ?? 0,
                battery: values["EssDischargePower"] ?? 0,
                soc: values["EssSoc"] ?? 0,
                state: values["State"] ?? 0,
                batteryPresent: socVorhanden,
                date: .now,
                reachable: true
            )
        } catch {
            return .offline()
        }
    }
}

extension Int {
    /// Leistung lesbar: 812 → "812 W", 3450 → "3,45 kW"
    var powerText: String {
        let w = abs(self)
        if w < 1000 { return "\(w) W" }
        let digits = w >= 10000 ? 1 : 2
        let kw = String(format: "%.\(digits)f", Double(w) / 1000)
            .replacingOccurrences(of: ".", with: ",")
        return "\(kw) kW"
    }

    /// Nur der Zahlenwert, ohne Einheit
    var powerValue: String {
        let w = abs(self)
        if w < 1000 { return "\(w)" }
        let digits = w >= 10000 ? 1 : 2
        return String(format: "%.\(digits)f", Double(w) / 1000)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Passende Einheit zum Zahlenwert
    var powerUnit: String { abs(self) < 1000 ? "W" : "kW" }
}

extension FEMSSnapshot {
    /// Reichweite als kurzer Text: "7,3 h" oder "45 min".
    var runtimeText: String? {
        guard let r = runtime else { return nil }
        if r.hours < 1 {
            return "\(Int(r.hours * 60)) min"
        }
        return String(format: "%.1f h", r.hours).replacingOccurrences(of: ".", with: ",")
    }

    /// Zeitpunkt, an dem der Speicher leer beziehungsweise voll ist.
    var runtimeUntil: Date? {
        guard let r = runtime else { return nil }
        return Date.now.addingTimeInterval(r.hours * 3600)
    }

    /// Beschriftung für die Reichweite.
    var runtimeLabel: String {
        guard let r = runtime else { return "SPEICHER" }
        return r.charging ? "BIS VOLL" : "REICHWEITE"
    }
}

// MARK: - Gemeinsamer Zwischenspeicher

/// Legt den letzten Messwert in der App Group ab.
///
/// Die Menüleisten-App fragt alle 30 Sekunden ab und schreibt das Ergebnis
/// hierher. Das Widget liest es, statt selbst ins Netz zu gehen — das ist
/// schneller, spart Abfragen und funktioniert auch dann, wenn die Extension
/// keine Berechtigung für das lokale Netzwerk erhalten hat.
enum SnapshotCache {
    private static let schluessel = "lastSnapshot"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: FEMSConfig.suiteName) }

    /// Datei im Container der App Group. Sie ist der verlässlichere Weg:
    /// gemeinsame UserDefaults funktionieren bei ad-hoc signierten Builds
    /// nicht immer, der Dateizugriff dagegen schon.
    private static var datei: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: FEMSConfig.suiteName)?
            .appendingPathComponent("snapshot.json")
    }

    static func speichern(_ snapshot: FEMSSnapshot) {
        guard let daten = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(daten, forKey: schluessel)
        if let datei {
            try? daten.write(to: datei, options: .atomic)
        }
    }

    /// Gelesener Messwert, sofern er nicht älter als `maxAlter` Sekunden ist.
    /// Zuerst wird die Datei versucht, dann die gemeinsamen Einstellungen.
    static func laden(maxAlter: TimeInterval = 900) -> FEMSSnapshot? {
        for daten in [datei.flatMap { try? Data(contentsOf: $0) },
                      defaults?.data(forKey: schluessel)].compactMap({ $0 }) {
            if let snapshot = try? JSONDecoder().decode(FEMSSnapshot.self, from: daten),
               Date.now.timeIntervalSince(snapshot.date) <= maxAlter {
                return snapshot
            }
        }
        return nil
    }

    /// Alter des gespeicherten Messwerts in Sekunden, für die Fehlersuche.
    static func alter() -> TimeInterval? {
        guard let daten = datei.flatMap({ try? Data(contentsOf: $0) }) ?? defaults?.data(forKey: schluessel),
              let snapshot = try? JSONDecoder().decode(FEMSSnapshot.self, from: daten)
        else { return nil }
        return Date.now.timeIntervalSince(snapshot.date)
    }
}
