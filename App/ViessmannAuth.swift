import Foundation
import AppKit

/// Führt die Anmeldung bei Viessmann durch: Autorisierungsseite im
/// Systembrowser öffnen, den Rückruf lokal entgegennehmen, Code gegen
/// Tokens tauschen. Das Passwort gibt der Nutzer ausschließlich bei
/// Viessmann ein.
@MainActor
final class ViessmannAuth: ObservableObject {
    @Published var laeuft = false
    @Published var meldung: String?

    private var server: LoopbackServer?

    func anmelden() {
        guard ViessmannConfig.isConfigured else {
            meldung = "Bitte zuerst die Client-ID eintragen"
            return
        }
        let pkce = ViessmannClient.PKCE()
        guard let url = ViessmannClient.authorizeURL(pkce: pkce) else {
            meldung = "Autorisierungs-URL konnte nicht gebildet werden"
            return
        }

        laeuft = true
        meldung = "Warte auf Anmeldung im Browser …"

        let server = LoopbackServer(port: ViessmannConfig.redirectPort)
        self.server = server

        Task {
            do {
                async let code = server.warteAufCode()
                NSWorkspace.shared.open(url)
                let erhaltenerCode = try await code
                try await ViessmannClient.tokenHolen(code: erhaltenerCode, pkce: pkce)
                meldung = "Verbunden"
            } catch {
                meldung = error.localizedDescription
            }
            server.stoppen()
            self.server = nil
            laeuft = false
        }
    }

    func abbrechen() {
        server?.stoppen()
        server = nil
        laeuft = false
        meldung = nil
    }

    func abmelden() {
        ViessmannConfig.abmelden()
        meldung = "Abgemeldet"
    }
}
