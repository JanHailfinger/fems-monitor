import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Ein Satz kumulierter Zählerstände, wie ihn das FEMS liefert.
struct EnergyCounters: Sendable, Equatable {
    var production = 0        // Wh, kumuliert
    var consumption = 0
    var gridBuy = 0
    var gridSell = 0
    var essCharge = 0
    var essDischarge = 0
    var soc = 0
}

/// Tagesbilanz, aus der Differenz der Zählerstände gebildet.
struct DayTotals: Identifiable, Sendable {
    var date: Date
    var production = 0
    var consumption = 0
    var gridBuy = 0
    var gridSell = 0
    var essCharge = 0
    var essDischarge = 0

    var id: Date { date }

    /// Anteil des Verbrauchs, der nicht aus dem Netz kam.
    var autarky: Double {
        guard consumption > 0 else { return 0 }
        return min(1, Double(consumption - gridBuy) / Double(consumption))
    }

    /// Anteil der Erzeugung, der im Haus blieb.
    var selfConsumption: Double {
        guard production > 0 else { return 0 }
        return min(1, Double(production - gridSell) / Double(production))
    }
}

/// Legt die Zählerstände regelmäßig in einer SQLite-Datei ab und rechnet
/// daraus Tagesbilanzen. Die Datei liegt in der App Group, damit auch das
/// Widget mitlesen kann.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "de.hailfinger.FEMSMonitor.history")

    private init() {
        oeffne()
    }

    private var dateiURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: FEMSConfig.suiteName)?
            .appendingPathComponent("history.sqlite")
    }

    private func oeffne() {
        guard let url = dateiURL else { return }
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            db = nil
            return
        }
        let schema = """
            CREATE TABLE IF NOT EXISTS readings (
                ts            INTEGER PRIMARY KEY,
                production    INTEGER NOT NULL,
                consumption   INTEGER NOT NULL,
                grid_buy      INTEGER NOT NULL,
                grid_sell     INTEGER NOT NULL,
                ess_charge    INTEGER NOT NULL,
                ess_discharge INTEGER NOT NULL,
                soc           INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS readings_ts ON readings(ts);
            """
        sqlite3_exec(db, schema, nil, nil, nil)
    }

    /// Schreibt einen Messpunkt. Unplausible Sätze (alles null) werden verworfen.
    func speichern(_ c: EnergyCounters, at zeit: Date = .now) {
        guard c.production > 0 || c.consumption > 0 || c.gridBuy > 0 || c.gridSell > 0 else { return }
        queue.sync {
            guard let db else { return }
            let sql = """
                INSERT OR REPLACE INTO readings
                (ts, production, consumption, grid_buy, grid_sell, ess_charge, ess_discharge, soc)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(zeit.timeIntervalSince1970))
            sqlite3_bind_int(stmt, 2, Int32(c.production))
            sqlite3_bind_int(stmt, 3, Int32(c.consumption))
            sqlite3_bind_int(stmt, 4, Int32(c.gridBuy))
            sqlite3_bind_int(stmt, 5, Int32(c.gridSell))
            sqlite3_bind_int(stmt, 6, Int32(c.essCharge))
            sqlite3_bind_int(stmt, 7, Int32(c.essDischarge))
            sqlite3_bind_int(stmt, 8, Int32(c.soc))
            sqlite3_step(stmt)
        }
    }

    /// Tagesbilanzen der letzten `tage` Tage, neueste zuerst.
    /// Der Tageswert ist die Differenz zwischen dem letzten und dem ersten
    /// Zählerstand des Tages.
    func tagesbilanzen(tage: Int = 14) -> [DayTotals] {
        queue.sync {
            guard let db else { return [] }
            let seit = Calendar.current.date(byAdding: .day, value: -tage, to: .now) ?? .now
            let sql = """
                SELECT
                    date(ts, 'unixepoch', 'localtime') AS tag,
                    MAX(production)    - MIN(production),
                    MAX(consumption)   - MIN(consumption),
                    MAX(grid_buy)      - MIN(grid_buy),
                    MAX(grid_sell)     - MIN(grid_sell),
                    MAX(ess_charge)    - MIN(ess_charge),
                    MAX(ess_discharge) - MIN(ess_discharge)
                FROM readings
                WHERE ts >= ?
                GROUP BY tag
                ORDER BY tag DESC
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(seit.timeIntervalSince1970))

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = .current

            var ergebnis: [DayTotals] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let cText = sqlite3_column_text(stmt, 0),
                      let tag = formatter.date(from: String(cString: cText)) else { continue }
                ergebnis.append(DayTotals(
                    date: tag,
                    production: Int(sqlite3_column_int(stmt, 1)),
                    consumption: Int(sqlite3_column_int(stmt, 2)),
                    gridBuy: Int(sqlite3_column_int(stmt, 3)),
                    gridSell: Int(sqlite3_column_int(stmt, 4)),
                    essCharge: Int(sqlite3_column_int(stmt, 5)),
                    essDischarge: Int(sqlite3_column_int(stmt, 6))
                ))
            }
            return ergebnis
        }
    }

    /// Anzahl gespeicherter Messpunkte und Zeitpunkt des ältesten.
    func bestand() -> (anzahl: Int, seit: Date?) {
        queue.sync {
            guard let db else { return (0, nil) }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*), MIN(ts) FROM readings", -1, &stmt, nil) == SQLITE_OK
            else { return (0, nil) }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, nil) }
            let anzahl = Int(sqlite3_column_int(stmt, 0))
            let ts = sqlite3_column_int64(stmt, 1)
            return (anzahl, ts > 0 ? Date(timeIntervalSince1970: TimeInterval(ts)) : nil)
        }
    }
}

extension Int {
    /// Wattstunden als kWh-Text: 12646 → "12,65"
    var kilowattHourText: String {
        String(format: "%.2f", Double(self) / 1000).replacingOccurrences(of: ".", with: ",")
    }
}
