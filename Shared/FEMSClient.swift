import Foundation

/// Konfiguration der Anlage. Anpassbar in der App, Standardwerte hier.
enum FEMSConfig {
    static let defaultHost = "192.168.1.100"   // in den Einstellungen anpassen
    static let defaultPassword = "user"          // Standard-Gastzugang, nur lesend
    static let suiteName = "group.de.hailfinger.FEMSMonitor"

    static var host: String {
        UserDefaults(suiteName: suiteName)?.string(forKey: "host") ?? defaultHost
    }
    static var password: String {
        UserDefaults(suiteName: suiteName)?.string(forKey: "password") ?? defaultPassword
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
struct FEMSSnapshot: Sendable, Equatable {
    var production: Int = 0        // PV-Erzeugung, immer positiv
    var consumption: Int = 0       // Hausverbrauch
    var grid: Int = 0              // + Bezug, − Einspeisung
    var battery: Int = 0           // + entladen, − laden
    var soc: Int = 0               // Ladezustand in Prozent
    var state: Int = 0             // 0 Ok, 1 Info, 2 Warning, 3 Fault
    var batteryPresent: Bool = true
    var date: Date = .now
    var reachable: Bool = true

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
