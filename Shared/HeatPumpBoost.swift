import Foundation

/// Einstellungen der Überschussautomatik.
enum BoostConfig {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: FEMSConfig.suiteName) }

    /// Automatik überhaupt aktiv. Standard: aus — sie schreibt an der Heizung.
    static var enabled: Bool {
        get { defaults?.bool(forKey: "boostEnabled") ?? false }
        set { defaults?.set(newValue, forKey: "boostEnabled") }
    }

    /// Ab wieviel Watt Einspeisung gilt es als Überschuss.
    static var thresholdWatt: Int {
        let w = defaults?.integer(forKey: "boostThreshold") ?? 0
        return w > 0 ? w : 5000
    }

    /// Fenster für den gleitenden Mittelwert der Einspeisung, in Minuten.
    /// Kurze Wolkenlöcher fallen damit nicht ins Gewicht.
    static var averageMinutes: Int {
        let m = defaults?.integer(forKey: "boostAverage") ?? 0
        return m > 0 ? m : 5
    }

    /// Ausschaltschwelle als Anteil der Einschaltschwelle. 0,7 heißt:
    /// eingeschaltet wird bei 5.000 W, ausgeschaltet erst unter 3.500 W.
    static var offFactor: Double {
        let f = defaults?.double(forKey: "boostOffFactor") ?? 0
        return f > 0 ? f : 0.7
    }

    /// Angenommene Leistungsaufnahme der Wärmepumpe im Boost, in Watt.
    /// Sie wird bei aktivem Boost zur Einspeisung hinzugerechnet, damit die
    /// Automatik nicht abschaltet, nur weil sie selbst den Überschuss frisst.
    static var heatPumpWatt: Int {
        let w = defaults?.integer(forKey: "boostHeatPumpWatt") ?? 0
        return w > 0 ? w : 6000
    }

    /// Hygienefunktion mitschalten — bringt den Verdichter auf Volllast.
    static var useHygiene: Bool {
        get { defaults?.object(forKey: "boostHygiene") as? Bool ?? true }
        set { defaults?.set(newValue, forKey: "boostHygiene") }
    }

    /// Wie lange der Überschuss anliegen muss, bevor geschaltet wird.
    static var delayMinutes: Int {
        let m = defaults?.integer(forKey: "boostDelay") ?? 0
        return m > 0 ? m : 10
    }

    /// Wie lange ein einmal gesetzter Zustand mindestens hält.
    static var holdMinutes: Int {
        let m = defaults?.integer(forKey: "boostHold") ?? 0
        return m > 0 ? m : 30
    }

    /// Solltemperatur im Boost und im Normalbetrieb.
    static var boostTemperature: Int {
        let t = defaults?.integer(forKey: "boostTemp") ?? 0
        return t > 0 ? t : 58
    }
    static var normalTemperature: Int {
        let t = defaults?.integer(forKey: "boostNormalTemp") ?? 0
        return t > 0 ? t : 52
    }

    /// Nur innerhalb dieser Stunden aktiv (Ortszeit).
    static var startHour: Int {
        defaults?.object(forKey: "boostStartHour") as? Int ?? 9
    }
    static var endHour: Int {
        defaults?.object(forKey: "boostEndHour") as? Int ?? 18
    }

    /// Höchstzahl an Schaltvorgängen pro Tag — schützt vor Rate-Limit und
    /// vor unruhigem Betrieb der Wärmepumpe.
    static var maxSwitchesPerDay: Int {
        let n = defaults?.integer(forKey: "boostMaxSwitches") ?? 0
        return n > 0 ? n : 8
    }
}

/// Zustand der Automatik, wie er in der Oberfläche erscheint.
struct BoostStatus: Sendable, Equatable {
    enum Phase: String, Sendable {
        case aus = "Automatik aus"
        case wartetAufUeberschuss = "wartet auf Überschuss"
        case ueberschussErkannt = "Überschuss erkannt, prüft Dauer"
        case aktiv = "Boost aktiv"
        case ausserhalbZeitfenster = "außerhalb des Zeitfensters"
        case limitErreicht = "Tageslimit an Schaltungen erreicht"
    }

    var phase: Phase = .aus
    var seit: Date?
    var schaltungenHeute: Int = 0
    var letzterFehler: String?
    /// Gleitender Mittelwert der Einspeisung in Watt.
    var mittelwert: Int = 0
    var messpunkte: Int = 0
    /// Anteil, der der Wärmepumpe zugerechnet wird.
    var eigenlast: Int = 0
}

/// Hebt bei PV-Überschuss die Warmwasser-Solltemperatur an und nimmt sie
/// zurück, sobald der Überschuss wegfällt.
///
/// Der Überschuss kommt vom lokalen FEMS, geschrieben wird nur bei einem
/// echten Zustandswechsel — die Viessmann-Cloud begrenzt die Aufrufe.
actor HeatPumpBoost {
    static let shared = HeatPumpBoost()

    private var boostAktiv = false
    private var ueberschussSeit: Date?
    private var letzterWechsel: Date = .distantPast
    private var schaltungen: [Date] = []
    /// Messwerte für den gleitenden Mittelwert.
    private var verlauf: [(zeit: Date, watt: Int)] = []
    private(set) var status = BoostStatus()

    /// Wird bei jeder FEMS-Abfrage aufgerufen.
    ///
    /// `netto` ist der Netzwert mit umgedrehtem Vorzeichen: positiv bei
    /// Einspeisung, negativ bei Bezug. `waermepumpe` ist die gemessene
    /// Aufnahme der Wärmepumpe, falls bekannt.
    func pruefe(netto: Int, waermepumpe: Int? = nil) async {
        let jetzt = Date.now

        // Bei aktivem Boost zählt die eigene Last zum verfügbaren Überschuss:
        // ohne sie wäre die Leistung ja weiterhin eingespeist worden.
        let eigenlast = boostAktiv
            ? max(waermepumpe ?? 0, waermepumpe == nil ? BoostConfig.heatPumpWatt : 0)
            : 0
        let einspeisung = netto + eigenlast

        verlauf.append((jetzt, einspeisung))
        let fenster = Double(BoostConfig.averageMinutes * 60)
        verlauf.removeAll { jetzt.timeIntervalSince($0.zeit) > fenster }

        let mittel = verlauf.isEmpty ? 0
            : verlauf.reduce(0) { $0 + $1.watt } / verlauf.count
        status.mittelwert = mittel
        status.messpunkte = verlauf.count
        status.eigenlast = eigenlast

        guard BoostConfig.enabled, ViessmannConfig.isConnected else {
            status.phase = .aus
            return
        }

        schaltungen.removeAll { !Calendar.current.isDateInToday($0) }
        status.schaltungenHeute = schaltungen.count

        let stunde = Calendar.current.component(.hour, from: jetzt)
        let imFenster = stunde >= BoostConfig.startHour && stunde < BoostConfig.endHour
        if !imFenster {
            if boostAktiv { await schalte(false) }
            status.phase = .ausserhalbZeitfenster
            return
        }

        if schaltungen.count >= BoostConfig.maxSwitchesPerDay {
            status.phase = .limitErreicht
            return
        }

        let haltezeitVorbei = jetzt.timeIntervalSince(letzterWechsel)
            >= Double(BoostConfig.holdMinutes * 60)

        // Der Mittelwert wird erst belastbar, wenn das Fenster gefüllt ist.
        let fensterVoll = verlauf.count >= 3
            && jetzt.timeIntervalSince(verlauf[0].zeit) >= fenster * 0.6

        let ein = BoostConfig.thresholdWatt
        let aus = Int(Double(ein) * BoostConfig.offFactor)

        if mittel >= ein, fensterVoll {
            if ueberschussSeit == nil { ueberschussSeit = jetzt }
            let dauer = jetzt.timeIntervalSince(ueberschussSeit ?? jetzt)
            if !boostAktiv, dauer >= Double(BoostConfig.delayMinutes * 60), haltezeitVorbei {
                await schalte(true)
            } else if !boostAktiv {
                status.phase = .ueberschussErkannt
                status.seit = ueberschussSeit
            }
        } else if mittel < aus {
            ueberschussSeit = nil
            if boostAktiv, haltezeitVorbei {
                await schalte(false)
            } else if !boostAktiv {
                status.phase = .wartetAufUeberschuss
            }
        } else {
            // Zwischen Aus- und Einschaltschwelle: Zustand halten
            ueberschussSeit = nil
            if !boostAktiv { status.phase = .wartetAufUeberschuss }
        }
    }

    private func schalte(_ ein: Bool) async {
        let ziel = ein ? BoostConfig.boostTemperature : BoostConfig.normalTemperature
        do {
            // Der Sollwert löst die Ladung aus, die Hygienefunktion hebt
            // zusätzlich die Verdichterdrehzahl auf Volllast.
            try await ViessmannClient.setzeWarmwasserSoll(ziel)
            if BoostConfig.useHygiene {
                try await ViessmannClient.setzeHygiene(ein)
            }
            boostAktiv = ein
            letzterWechsel = .now
            schaltungen.append(.now)
            status.phase = ein ? .aktiv : .wartetAufUeberschuss
            status.seit = ein ? .now : nil
            status.schaltungenHeute = schaltungen.count
            status.letzterFehler = nil
        } catch {
            status.letzterFehler = error.localizedDescription
        }
    }

    /// Setzt Solltemperatur und Hygienefunktion unabhängig von der
    /// Automatik auf Normalbetrieb zurück.
    func zuruecksetzen() async {
        guard ViessmannConfig.isConnected else { return }
        do {
            try await ViessmannClient.setzeWarmwasserSoll(BoostConfig.normalTemperature)
            try? await ViessmannClient.setzeHygiene(false)
            boostAktiv = false
            status.phase = BoostConfig.enabled ? .wartetAufUeberschuss : .aus
        } catch {
            status.letzterFehler = error.localizedDescription
        }
    }
}
