# FEMS Monitor

Ein natives macOS-Widget und eine Menüleisten-Anzeige für FENECON-Stromspeicher.
Liest die Anlagenwerte direkt über die lokale REST/JSON-Schnittstelle des FEMS —
ohne Cloud, ohne Konto, ohne Umweg über das FENECON-Portal.

## Was es zeigt

Einen Energiefluss-Ring mit vier Sektoren, deren Länge sich nach der Leistung richtet:

| Sektor | Kanal | Bedeutung |
|---|---|---|
| oben | `ProductionActivePower` | PV-Erzeugung |
| rechts | `ConsumptionActivePower` | Hausverbrauch |
| unten | `EssDischargePower` | Speicherleistung |
| links | `GridActivePower` | Netzanschlusspunkt |

In der Mitte steht der Ladezustand, darunter der Zustand des Speichers
(`LÄDT`, `ENTLÄDT`, `SPEICHER`, `GETRENNT`). Der Netzsektor färbt sich rot
bei Bezug und grün bei Einspeisung.

Enthalten sind:

- **Desktop-Widget** in drei Größen (klein, mittel, groß)
- **Menüleisten-Anzeige** mit animiertem Energiefluss und Werteliste
- **Einstellungen** für IP, Passwort und Aktualisierungsintervalle, mit Verbindungstest

## Voraussetzungen

- macOS 14 oder neuer
- Xcode (für den Build)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Ein FENECON-Speichersystem im selben Netzwerk, erreichbar über HTTP
- Die FEMS-App **REST/JSON lesend** — im Standard-Lieferumfang des FEMS enthalten

## Installation

```bash
git clone https://github.com/JanHailfinger/fems-monitor.git
cd fems-monitor
./build.sh
```

Das Skript erzeugt das Xcode-Projekt, baut, signiert ad-hoc und installiert
nach `/Applications`. Danach:

1. Die App startet in der Menüleiste (kein Dock-Symbol)
2. Menüleistensymbol anklicken → **Einstellungen …** → IP-Adresse eintragen
3. **Verbindung testen** klicken
4. Rechtsklick auf den Desktop → **Widgets bearbeiten** → `FEMS Monitor` auswählen

Für den Autostart die App unter *Systemeinstellungen → Allgemein →
Anmeldeobjekte* eintragen.

## Konfiguration

Standardmäßig verbindet sich die App mit `192.168.1.100` und dem Gastzugang
des FEMS (Benutzer `x`, Passwort `user`, ausschließlich lesend). Beides ist
in den Einstellungen änderbar und wird in einer App Group abgelegt, damit
Widget und App dieselben Werte nutzen.

Die IP deines FEMS findest du im Router oder im FENECON Online-Monitoring.

## Wie die Daten geholt werden

Ein einziger Aufruf mit regulärem Ausdruck liefert alle benötigten Kanäle:

```
GET http://<IP>/rest/channel/_sum/(EssSoc|EssDischargePower|GridActivePower|ProductionActivePower|ConsumptionActivePower|State)
Authorization: Basic <base64 von "x:passwort">
```

Antwort:

```json
[{"address":"_sum/EssSoc","type":"INTEGER","accessMode":"RO","unit":"%","value":87}]
```

Die Schnittstelle verlangt Header-Authentifizierung; Zugangsdaten in der URL
werden abgelehnt.

### Warum `EssDischargePower` und nicht `EssActivePower`

Bei Hybrid-Wechselrichtern enthält `EssActivePower` die durchgeleitete
PV-Erzeugung und zeigt deshalb auch dann Leistung an, wenn die Batterie gar
nichts tut. `EssDischargePower` ist die tatsächliche Leistung des Speichers.

### Weitere Kanäle

Ein FEMS liefert weit mehr als die Übersichtswerte — auf einer Home-10-Anlage
rund 2.700 Kanäle über 40 Komponenten, darunter Einzelzellspannungen der
Batterie, Wechselrichterregister und die MPPT-Strings einzeln. Alles auflisten:

```bash
curl -s -u x:user "http://<IP>/rest/channel/.*/.*" | python3 -m json.tool
```

## Aktualisierungsintervall

Beide Intervalle sind in den Einstellungen wählbar:

| Einstellung | Auswahl | Standard |
|---|---|---|
| Menüleiste | 5 s bis 5 min | 30 s |
| Widget | 5 bis 60 min | 5 min |

WidgetKit rendert Standbilder, ein Widget kann sich nicht laufend selbst
aktualisieren, und der eingestellte Wert ist für das System nur ein Wunsch —
bei knappem Budget lädt es seltener. Solange die Menüleisten-App läuft, stößt
sie bei jeder eigenen Abfrage zusätzlich eine Widget-Aktualisierung an; dann
ist das Widget so frisch wie das Menüleisten-Intervall. Ist eine Anlage nicht
erreichbar, wird höchstens 2 Minuten bis zum nächsten Versuch gewartet.

## Eigene Bundle-ID

Das Projekt verwendet `de.hailfinger.FEMSMonitor`. Wer das ändern möchte,
passt `project.yml`, beide `.entitlements` und `FEMSConfig.suiteName` in
`Shared/FEMSClient.swift` an — App Group und Bundle-Präfix müssen
zusammenpassen.

## Aufbau

```
App/       Menüleisten-App und Einstellungen
Widget/    WidgetKit-Extension mit den drei Größen
Shared/    REST-Client und der Energiefluss-Ring (von beiden genutzt)
```

## Hinweise

Die App liest ausschließlich. Sie sendet keine Steuerbefehle an die Anlage und
überträgt keine Daten nach außen — die einzige Netzwerkverbindung geht zum FEMS
im lokalen Netz.

Kein offizielles Produkt der FENECON GmbH und nicht mit ihr verbunden. FENECON
und FEMS sind Marken der FENECON GmbH.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
