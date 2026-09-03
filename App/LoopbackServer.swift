import Foundation
import Network

/// Nimmt den OAuth-Rückruf auf `http://localhost:<port>/` entgegen.
///
/// Viessmann erlaubt als Redirect-URI nur http-Adressen, keine eigenen
/// URL-Schemata. Deshalb lauscht die App während der Anmeldung kurz auf
/// dem Loopback-Interface und liest den Autorisierungscode aus der Anfrage.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var fortsetzung: CheckedContinuation<String, Error>?
    private let port: UInt16

    init(port: UInt16 = 4200) {
        self.port = port
    }

    enum Fehler: LocalizedError {
        case portBelegt(UInt16)
        case abgebrochen
        case keinCode(String)

        var errorDescription: String? {
            switch self {
            case .portBelegt(let p):  return "Port \(p) ist belegt — bitte andere Anwendung schließen"
            case .abgebrochen:        return "Anmeldung abgebrochen"
            case .keinCode(let text): return "Kein Autorisierungscode erhalten (\(text))"
            }
        }
    }

    /// Startet den Listener und wartet auf den Code. Bricht nach `timeout` ab.
    func warteAufCode(timeout: TimeInterval = 300) async throws -> String {
        let parameter = NWParameters.tcp
        parameter.allowLocalEndpointReuse = true
        parameter.requiredInterfaceType = .loopback

        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: parameter, on: nwPort)
        else { throw Fehler.portBelegt(port) }

        self.listener = listener

        return try await withThrowingTaskGroup(of: String.self) { gruppe in
            gruppe.addTask { [weak self] in
                try await withCheckedThrowingContinuation { fortsetzung in
                    self?.fortsetzung = fortsetzung
                    listener.newConnectionHandler = { [weak self] verbindung in
                        self?.behandle(verbindung)
                    }
                    listener.start(queue: .global(qos: .userInitiated))
                }
            }
            gruppe.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw Fehler.abgebrochen
            }
            defer { gruppe.cancelAll() }
            guard let ergebnis = try await gruppe.next() else { throw Fehler.abgebrochen }
            stoppen()
            return ergebnis
        }
    }

    private func behandle(_ verbindung: NWConnection) {
        verbindung.start(queue: .global(qos: .userInitiated))
        verbindung.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] daten, _, _, _ in
            guard let self, let daten, let anfrage = String(data: daten, encoding: .utf8) else { return }

            // Erste Zeile: "GET /?code=... HTTP/1.1"
            let pfad = anfrage.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let komponenten = URLComponents(string: "http://localhost" + pfad)
            let code = komponenten?.queryItems?.first(where: { $0.name == "code" })?.value

            let seite = code == nil
                ? "<h2>Keine Autorisierung erhalten</h2><p>Du kannst dieses Fenster schließen.</p>"
                : "<h2>Angemeldet</h2><p>Du kannst dieses Fenster schließen und zu FEMS Monitor zurückkehren.</p>"
            let antwort = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Connection: close\r
                \r
                <!doctype html><html lang="de"><head><meta charset="utf-8">
                <title>FEMS Monitor</title></head>
                <body style="font-family:-apple-system,sans-serif;padding:3rem;text-align:center">
                \(seite)</body></html>
                """

            verbindung.send(content: antwort.data(using: .utf8), completion: .contentProcessed { _ in
                verbindung.cancel()
            })

            let fortsetzung = self.fortsetzung
            self.fortsetzung = nil
            if let code {
                fortsetzung?.resume(returning: code)
            } else {
                let fehlerText = komponenten?.queryItems?
                    .first(where: { $0.name == "error_description" || $0.name == "error" })?.value ?? "unbekannt"
                fortsetzung?.resume(throwing: Fehler.keinCode(fehlerText))
            }
        }
    }

    func stoppen() {
        listener?.cancel()
        listener = nil
    }
}
