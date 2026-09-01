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
- **Verlauf** mit Tagesbilanzen aus einer lokalen SQLite-Datenbank
- **Wärmepumpe** aus der Viessmann-Cloud, optional

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

## Verlauf

Die App legt alle 5 Minuten die kumulierten Zählerstände in einer SQLite-Datei
ab (`history.sqlite` im App-Group-Container). Die Tagesbilanz entsteht als
Differenz zwischen erstem und letztem Stand des Tages, bleibt also auch dann
korrekt, wenn der Rechner zwischendurch aus war.

Menüleiste → **Verlauf …** zeigt ein Balkendiagramm, umschaltbar zwischen
Erzeugung, Verbrauch, Einspeisung und Netzbezug, dazu eine Tabelle mit
Autarkiegrad je Zeitfenster.

Auflösung und Zeitraum sind frei wählbar:

| Auflösung | vorgeschlagener Zeitraum |
|---|---|
| 5 Minuten | 6 Stunden |
| 15 Minuten | 24 Stunden |
| Stunde | 3 Tage |
| Tag | 30 Tage |
| Monat | 1 Jahr |

Der Wert eines Fensters entsteht als Summe der Differenzen aufeinanderfolgender
Messpunkte, nicht als `MAX − MIN` des Fensters — sonst lieferten feine
Auflösungen, bei denen ein Fenster nur einen Messpunkt enthält, immer null.

Die Datenbank lässt sich auch direkt auswerten:

```bash
sqlite3 ~/Library/Group\ Containers/group.de.hailfinger.FEMSMonitor/history.sqlite \
  "SELECT date(ts,'unixepoch','localtime') tag,
          (MAX(production)-MIN(production))/1000.0 erzeugung_kwh,
          (MAX(grid_sell)-MIN(grid_sell))/1000.0   einspeisung_kwh
   FROM readings GROUP BY tag;"
```

### Warum kein Zugriff auf die FEMS-Historie

Das FEMS speichert selbst Verlaufsdaten (`rrd4j0`), gibt sie aber nicht über
die REST-App heraus — `/rest/jsonrpc` antwortet mit `Unhandled REST target`.
Erreichbar wären sie nur über die Websocket-API auf Port 8085, die eine eigene
Authentifizierung und ein anderes Protokoll verlangt. Deshalb der eigene
Verlauf, der ab Installation aufgebaut wird.

### Speicherwerte bei Hybrid-Wechselrichtern

`EssActiveChargeEnergy` und `EssActiveDischargeEnergy` zählen beim Hybrid-Gerät
die durchgeleitete PV-Erzeugung mit und liegen daher deutlich über der
tatsächlichen Batterienutzung. Die Tabelle zeigt deshalb nur Erzeugung,
Verbrauch, Einspeisung und Netzbezug.

## Wärmepumpe anbinden (optional)

Läuft im Haus eine Viessmann-Wärmepumpe, zeigt die Menüleisten-Ansicht deren
Betriebszustand und Temperaturen neben den PV-Werten.

1. Im [Viessmann-Entwicklerportal](https://app.developer.viessmann-climatesolutions.com)
   unter *My Dashboard* einen Client anlegen, reCAPTCHA deaktivieren und als
   Redirect-URI `de.hailfinger.femsmonitor://oauth` eintragen
2. Client-ID in *Einstellungen → Wärmepumpe (Viessmann)* eintragen
3. **Bei Viessmann anmelden** — die Anmeldung läuft im Systembrowser

Technisch: Authorization Code Flow mit PKCE gegen
`https://iam.viessmann-climatesolutions.com/idp/v3/authorize`, Scopes
`IoT User offline_access`, Daten von
`https://api.viessmann-climatesolutions.com/iot/v2`. Die App erneuert den
Access-Token selbstständig über den Refresh-Token.

Die Cloud begrenzt die Zahl der Aufrufe pro Tag, deshalb ist das Intervall
getrennt einstellbar (Standard 10 Minuten, rund 290 Aufrufe täglich). Bei
Überschreitung meldet die App „Abrufgrenze der Viessmann-Cloud erreicht".

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
App/       Menüleisten-App, Einstellungen und Verlaufsansicht
Widget/    WidgetKit-Extension mit den drei Größen
Shared/    REST-Client, Energiefluss-Ring und SQLite-Verlauf
```

## Hinweise

Die App liest ausschließlich. Sie sendet keine Steuerbefehle an die Anlage und
überträgt keine Daten nach außen — die einzige Netzwerkverbindung geht zum FEMS
im lokalen Netz.

Kein offizielles Produkt der FENECON GmbH und nicht mit ihr verbunden. FENECON
und FEMS sind Marken der FENECON GmbH.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
