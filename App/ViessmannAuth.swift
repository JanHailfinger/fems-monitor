import Foundation
import AuthenticationServices
import AppKit

/// Führt die Anmeldung bei Viessmann im Systembrowser durch. Das Passwort
/// gibt der Nutzer ausschließlich auf der Viessmann-Seite ein; die App sieht
/// nur den zurückgereichten Autorisierungscode.
@MainActor
final class ViessmannAuth: NSObject, ObservableObject {
    @Published var laeuft = false
    @Published var meldung: String?

    private var session: ASWebAuthenticationSession?

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
        meldung = nil

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "de.hailfinger.femsmonitor"
        ) { [weak self] rueckgabe, fehler in
            guard let self else { return }
            Task { @MainActor in
                self.laeuft = false
                if let fehler {
                    let abgebrochen = (fehler as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    self.meldung = abgebrochen ? nil : fehler.localizedDescription
                    return
                }
                guard let rueckgabe,
                      let code = URLComponents(url: rueckgabe, resolvingAgainstBaseURL: false)?
                          .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    self.meldung = "Kein Autorisierungscode erhalten"
                    return
                }
                do {
                    try await ViessmannClient.tokenHolen(code: code, pkce: pkce)
                    self.meldung = "Verbunden"
                } catch {
                    self.meldung = error.localizedDescription
                }
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        session.start()
        self.session = session
    }

    func abmelden() {
        ViessmannConfig.abmelden()
        meldung = "Abgemeldet"
    }
}

extension ViessmannAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
