import Foundation
import CryptoKit

/// Zugangsdaten und Endpunkte der Viessmann-Cloud.
enum ViessmannConfig {
    static let authorizeURL = "https://iam.viessmann-climatesolutions.com/idp/v3/authorize"
    static let tokenURL = "https://iam.viessmann-climatesolutions.com/idp/v3/token"
    static let apiBase = "https://api.viessmann-climatesolutions.com/iot/v2"
    static let scopes = "IoT User offline_access"
    static let redirectURI = "de.hailfinger.femsmonitor://oauth"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: FEMSConfig.suiteName) }

    /// Im Viessmann-Entwicklerportal angelegte Client-ID.
    static var clientID: String {
        get { defaults?.string(forKey: "viClientID") ?? "" }
        set { defaults?.set(newValue, forKey: "viClientID") }
    }

    static var refreshToken: String? {
        get { defaults?.string(forKey: "viRefreshToken") }
        set { defaults?.set(newValue, forKey: "viRefreshToken") }
    }

    static var accessToken: String? {
        get { defaults?.string(forKey: "viAccessToken") }
        set { defaults?.set(newValue, forKey: "viAccessToken") }
    }

    static var accessTokenExpiry: Date {
        get { Date(timeIntervalSince1970: defaults?.double(forKey: "viTokenExpiry") ?? 0) }
        set { defaults?.set(newValue.timeIntervalSince1970, forKey: "viTokenExpiry") }
    }

    /// Abfrageintervall in Minuten. Die Cloud begrenzt die Zahl der Aufrufe
    /// pro Tag, deshalb deutlich seltener als beim lokalen FEMS.
    static var pollMinutes: Int {
        let wert = defaults?.integer(forKey: "viPollMinutes") ?? 0
        return wert > 0 ? wert : 10
    }

    static var isConfigured: Bool { !clientID.isEmpty }
    static var isConnected: Bool { refreshToken != nil }

    static func abmelden() {
        defaults?.removeObject(forKey: "viRefreshToken")
        defaults?.removeObject(forKey: "viAccessToken")
        defaults?.removeObject(forKey: "viTokenExpiry")
    }
}

/// Zustand der Wärmepumpe, so weit für die Anzeige nötig.
struct HeatPumpState: Sendable, Equatable {
    var installationID: Int = 0
    var deviceName: String = ""
    var outsideTemperature: Double?
    var supplyTemperature: Double?
    var hotWaterTemperature: Double?
    var compressorActive: Bool = false
    var compressorHours: Double?
    var compressorStarts: Int?
    /// Kumulierter Stromverbrauch in kWh, sofern das Gerät ihn liefert.
    var powerConsumptionToday: Double?
    var burnerOrHeatingActive: Bool = false
    var date: Date = .now
}

/// Spricht mit der Viessmann-Cloud: OAuth2 mit PKCE, Token-Erneuerung,
/// Abruf der Gerätemerkmale.
struct ViessmannClient {

    // MARK: - PKCE

    struct PKCE {
        let verifier: String
        var challenge: String {
            let hash = SHA256.hash(data: Data(verifier.utf8))
            return Data(hash).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        init() {
            var bytes = [UInt8](repeating: 0, count: 64)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            verifier = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    static func authorizeURL(pkce: PKCE) -> URL? {
        var comps = URLComponents(string: ViessmannConfig.authorizeURL)
        comps?.queryItems = [
            .init(name: "client_id", value: ViessmannConfig.clientID),
            .init(name: "redirect_uri", value: ViessmannConfig.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: ViessmannConfig.scopes)
        ]
        return comps?.url
    }

    // MARK: - Token

    private struct TokenAntwort: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    /// Tauscht den Autorisierungscode gegen Tokens.
    static func tokenHolen(code: String, pkce: PKCE) async throws {
        var felder = [
            "grant_type": "authorization_code",
            "client_id": ViessmannConfig.clientID,
            "redirect_uri": ViessmannConfig.redirectURI,
            "code": code,
            "code_verifier": pkce.verifier
        ]
        try await tokenAnfrage(&felder)
    }

    /// Holt einen frischen Access-Token, falls der alte abgelaufen ist.
    static func tokenErneuern() async throws {
        guard let refresh = ViessmannConfig.refreshToken else {
            throw ViessmannFehler.nichtAngemeldet
        }
        var felder = [
            "grant_type": "refresh_token",
            "client_id": ViessmannConfig.clientID,
            "refresh_token": refresh
        ]
        try await tokenAnfrage(&felder)
    }

    private static func tokenAnfrage(_ felder: inout [String: String]) async throws {
        guard let url = URL(string: ViessmannConfig.tokenURL) else { throw ViessmannFehler.ungueltigeAntwort }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = felder
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ViessmannFehler.anmeldungFehlgeschlagen(String(data: data, encoding: .utf8) ?? "")
        }
        let antwort = try JSONDecoder().decode(TokenAntwort.self, from: data)
        ViessmannConfig.accessToken = antwort.access_token
        ViessmannConfig.accessTokenExpiry = Date().addingTimeInterval(TimeInterval(antwort.expires_in - 60))
        if let refresh = antwort.refresh_token {
            ViessmannConfig.refreshToken = refresh
        }
    }

    private static func gueltigerToken() async throws -> String {
        if let token = ViessmannConfig.accessToken, ViessmannConfig.accessTokenExpiry > .now {
            return token
        }
        try await tokenErneuern()
        guard let token = ViessmannConfig.accessToken else { throw ViessmannFehler.nichtAngemeldet }
        return token
    }

    // MARK: - Abfragen

    private static func get(_ pfad: String) async throws -> [String: Any] {
        let token = try await gueltigerToken()
        guard let url = URL(string: ViessmannConfig.apiBase + pfad) else {
            throw ViessmannFehler.ungueltigeAntwort
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ViessmannFehler.ungueltigeAntwort }
        if http.statusCode == 429 { throw ViessmannFehler.zuVieleAnfragen }
        guard http.statusCode == 200 else {
            throw ViessmannFehler.serverfehler(http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ViessmannFehler.ungueltigeAntwort
        }
        return json
    }

    /// Erste Installation samt Gateway und Gerät, wie sie die Cloud meldet.
    static func ersteAnlage() async throws -> (installation: Int, gateway: String, device: String) {
        let json = try await get("/equipment/installations?includeGateways=true")
        guard let liste = json["data"] as? [[String: Any]],
              let erste = liste.first,
              let id = erste["id"] as? Int,
              let gateways = erste["gateways"] as? [[String: Any]],
              let gateway = gateways.first,
              let serial = gateway["serial"] as? String
        else { throw ViessmannFehler.keineAnlage }

        let devices = gateway["devices"] as? [[String: Any]] ?? []
        let deviceID = devices.first(where: { ($0["deviceType"] as? String) == "heating" })?["id"] as? String
            ?? devices.first?["id"] as? String
            ?? "0"
        return (id, serial, deviceID)
    }

    /// Liest alle Merkmale des Geräts und übersetzt die für uns relevanten.
    static func zustand() async throws -> HeatPumpState {
        let anlage = try await ersteAnlage()
        let json = try await get("/features/installations/\(anlage.installation)/gateways/\(anlage.gateway)/devices/\(anlage.device)/features")
        guard let features = json["data"] as? [[String: Any]] else {
            throw ViessmannFehler.ungueltigeAntwort
        }

        var werte: [String: [String: Any]] = [:]
        for feature in features {
            guard let name = feature["feature"] as? String else { continue }
            werte[name] = feature["properties"] as? [String: Any] ?? [:]
        }

        func zahl(_ feature: String, _ property: String = "value") -> Double? {
            (werte[feature]?[property] as? [String: Any])?["value"] as? Double
        }
        func text(_ feature: String, _ property: String = "value") -> String? {
            (werte[feature]?[property] as? [String: Any])?["value"] as? String
        }
        func ganzzahl(_ feature: String, _ property: String) -> Int? {
            guard let v = (werte[feature]?[property] as? [String: Any])?["value"] else { return nil }
            if let i = v as? Int { return i }
            if let d = v as? Double { return Int(d) }
            return nil
        }

        var state = HeatPumpState()
        state.installationID = anlage.installation
        state.deviceName = anlage.device
        state.outsideTemperature = zahl("heating.sensors.temperature.outside")
        state.supplyTemperature = zahl("heating.circuits.0.sensors.temperature.supply")
        state.hotWaterTemperature = zahl("heating.dhw.sensors.temperature.hotWaterStorage")
        state.compressorActive = (text("heating.compressors.0", "active").map { $0 == "true" })
            ?? ((werte["heating.compressors.0"]?["active"] as? [String: Any])?["value"] as? Bool ?? false)
        state.compressorHours = zahl("heating.compressors.0.statistics", "hours")
        state.compressorStarts = ganzzahl("heating.compressors.0.statistics", "starts")
        state.burnerOrHeatingActive = (werte["heating.circuits.0.operating.modes.active"] != nil)
        state.powerConsumptionToday = zahl("heating.power.consumption.total.currentDay", "value")
            ?? zahl("heating.power.consumption.heating.currentDay", "value")
        return state
    }
}

enum ViessmannFehler: LocalizedError {
    case nichtAngemeldet
    case anmeldungFehlgeschlagen(String)
    case keineAnlage
    case zuVieleAnfragen
    case serverfehler(Int)
    case ungueltigeAntwort

    var errorDescription: String? {
        switch self {
        case .nichtAngemeldet:              return "Nicht bei Viessmann angemeldet"
        case .anmeldungFehlgeschlagen(let t): return "Anmeldung fehlgeschlagen: \(t.prefix(120))"
        case .keineAnlage:                  return "Keine Anlage im Konto gefunden"
        case .zuVieleAnfragen:              return "Abrufgrenze der Viessmann-Cloud erreicht"
        case .serverfehler(let code):       return "Viessmann-Server antwortete mit \(code)"
        case .ungueltigeAntwort:            return "Unerwartete Antwort der Viessmann-Cloud"
        }
    }
}
