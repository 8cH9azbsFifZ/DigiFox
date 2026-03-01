# Plan: Reporting Services Integration für DigiFox

## Übersicht

Automatisches Reporting von empfangenen und gesendeten Spots an externe Dienste —
immer dann, wenn Empfang aktiv ist und Daten vorliegen. Die Interfaces existieren
bereits in einem separaten Repository und werden hier integriert.

---

## 1. Unterstützte Services

| Service        | Protokoll        | Auth                      | Daten                          |
|----------------|------------------|---------------------------|--------------------------------|
| **WSPRnet**    | HTTP POST        | Callsign + Grid (kein PW) | WSPR-Spots (freq, SNR, drift)  |
| **PSK Reporter**| UDP/TCP          | Callsign + Grid (kein PW) | FT8/JS8/CW-Spots              |
| **RBN (Reverse Beacon)** | Telnet  | Callsign (kein PW)       | CW-Spots (WPM, freq, SNR)     |
| **APRS**       | APRS-IS TCP      | Callsign + **Passcode**   | Position, Status, Telemetrie   |
| **Winlink**    | SMTP/POP3 o. API | Callsign + **Passwort**   | Winlink-Messages               |

### Authentifizierungs-Matrix

```
Ohne Passwort (nur Callsign + Locator aus bestehender Config):
  ✓ WSPRnet
  ✓ PSK Reporter
  ✓ RBN

Mit Passwort/Passcode (zusätzliche Credentials nötig):
  ✗ APRS-IS    → benötigt APRS Passcode (errechenbar aus Callsign)
  ✗ Winlink    → benötigt Winlink-Passwort
```

---

## 2. Architektur

### 2.1 Service-Layer (neue Dateien)

```
DigiFox/
└── Services/
    └── Reporting/
        ├── ReportingManager.swift       ← Zentrale Steuerung aller Reporter
        ├── ReportingService.swift        ← Protocol-Definition
        ├── WSPRnetReporter.swift         ← WSPRnet Upload
        ├── PSKReporterService.swift      ← PSK Reporter UDP/TCP
        ├── RBNReporter.swift             ← Reverse Beacon Network Telnet
        ├── APRSISReporter.swift          ← APRS-IS TCP Client
        └── WinlinkReporter.swift         ← Winlink Integration
```

### 2.2 Protocol-Definition

```swift
/// Jeder Reporting-Service implementiert dieses Protocol
protocol ReportingService: AnyObject {
    var id: String { get }                    // z.B. "wspr", "psk", "rbn"
    var displayName: String { get }           // z.B. "WSPRnet", "PSK Reporter"
    var requiresPassword: Bool { get }        // false für WSPR/PSK/RBN
    var state: ReportingState { get }         // .idle, .connecting, .active, .error

    func connect(callsign: String, grid: String, password: String?) async throws
    func disconnect() async
    func report(spots: [Spot]) async throws   // Spots hochladen
}

enum ReportingState {
    case idle           // Service nicht aktiv
    case connecting     // Verbindung wird aufgebaut
    case active         // Verbunden, meldet Spots
    case error(String)  // Fehler (mit Nachricht)
}
```

### 2.3 ReportingManager (zentrale Steuerung)

```swift
@MainActor
class ReportingManager: ObservableObject {
    @Published var services: [any ReportingService]
    @Published var serviceStates: [String: ReportingState]  // id → state

    /// Wird von AppState aufgerufen wenn neue Spots dekodiert werden
    func reportSpots(_ spots: [Spot]) async { ... }

    /// Aktiviert/deaktiviert einzelne Services
    func toggle(serviceId: String, enabled: Bool) { ... }
}
```

### 2.4 Integration in AppState

```swift
// In AppState.swift — minimal-invasiv:
class AppState: ObservableObject {
    // ... bestehende Properties ...
    let reportingManager = ReportingManager()

    // In runFT8Demodulation(), runJS8Demodulation(), CW-Decode:
    // → Nach dem Dekodieren die Spots an reportingManager.reportSpots() weiterleiten
}
```

**Einhängepunkte** (wo Spots ans Reporting übergeben werden):

| Methode                   | Modus | Was wird reported           |
|---------------------------|-------|-----------------------------|
| `runFT8Demodulation()`    | FT8   | Dekodierte FT8-Messages     |
| `runJS8Demodulation()`    | JS8   | Dekodierte JS8-Messages     |
| CW-Decode-Loop            | CW    | Dekodierte CW-Spots (→ RBN) |
| WSPR-Decode (zukünftig)   | WSPR  | WSPR-Spots (→ WSPRnet)      |

---

## 3. Konfiguration

### 3.1 Settings-Erweiterung

```swift
// In Settings.swift — neue @AppStorage-Properties:
class AppSettings: ObservableObject {
    // ... bestehend ...

    // Reporting Services — ein/aus pro Service
    @AppStorage("reportWSPR")    var reportWSPR = false
    @AppStorage("reportPSK")     var reportPSK = false
    @AppStorage("reportRBN")     var reportRBN = false
    @AppStorage("reportAPRS")    var reportAPRS = false
    @AppStorage("reportWinlink") var reportWinlink = false

    // Credentials für passwort-pflichtige Services
    // (im Keychain statt AppStorage für Sicherheit)
    // aprsPasscode: String  → Keychain
    // winlinkPassword: String → Keychain
}
```

### 3.2 Settings-UI (neue Section in SettingsView)

Neue Form-Section **"Reporting"** in der bestehenden `SettingsView`,
eingefügt zwischen "Audio" und "Info":

```
┌─────────────────────────────────────────────────┐
│ Reporting                                        │
├─────────────────────────────────────────────────┤
│ ○ WSPRnet              ───────────── [  Toggle ] │
│ ○ PSK Reporter         ───────────── [  Toggle ] │
│ ○ Reverse Beacon       ───────────── [  Toggle ] │
│ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ │
│ ○ APRS-IS              ───────────── [  Toggle ] │
│   Passcode  ·······················  [  12345  ] │
│ ○ Winlink              ───────────── [  Toggle ] │
│   Passwort  ·······················  [ ••••••• ] │
├─────────────────────────────────────────────────┤
│ ℹ Callsign und Grid werden automatisch aus den  │
│   Station-Einstellungen oben übernommen.         │
└─────────────────────────────────────────────────┘
```

**Regeln:**
- Passcode/Passwort-Felder erscheinen nur, wenn der zugehörige Toggle AN ist
- Wenn Callsign leer ist → alle Toggles grau/disabled mit Hinweis
- APRS-Passcode kann optional automatisch berechnet werden (Standard-Algorithmus)

---

## 4. UI-Konzept: "Modem-Kontrollleuchten"

### 4.1 Platzierung

Die Status-Anzeige kommt in die bestehende `StatusToolbar` (topBarLeading),
direkt neben dem existierenden `USBStatusBadge`. So sieht man auf einen Blick:

```
┌──────────────────────────────────────────────────────┐
│ DL1ABC [📡 Digirig]  [●●○●○]              [Start]   │
│                        ↑↑↑↑↑                         │
│                        │││││                          │
│                        ││││└─ W = Winlink (grau=aus)  │
│                        │││└── A = APRS    (grau=aus)  │
│                        ││└─── R = RBN     (grün=aktiv)│
│                        │└──── P = PSK Rep (grün=aktiv)│
│                        └───── W = WSPRnet (gelb=verb.)│
└──────────────────────────────────────────────────────┘
```

### 4.2 Farbcodes (wie alte Modem-LEDs)

```
●  Grün     = Aktiv, verbunden, meldet Spots
●  Gelb     = Verbindung wird aufgebaut
●  Rot      = Fehler (Tap für Details)
○  Grau     = Service deaktiviert (ausgeschaltet in Config)
●  Grün+Blink = Gerade wird ein Spot übertragen
```

### 4.3 SwiftUI-Komponente: `ReportingStatusDots`

```swift
/// Kompakte LED-Anzeige für alle Reporting-Services
struct ReportingStatusDots: View {
    @EnvironmentObject var reportingManager: ReportingManager

    var body: some View {
        HStack(spacing: 3) {
            ForEach(reportingManager.services) { service in
                Circle()
                    .fill(color(for: service.state))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Capsule().fill(.black.opacity(0.3)))
    }
}
```

### 4.4 Detail-Popover (Tap auf die Dots)

Bei Tap auf die LED-Reihe öffnet sich ein kleines Popover:

```
┌──────────────────────────────┐
│  Reporting Status            │
├──────────────────────────────┤
│  ● WSPRnet      Aktiv   ↑3  │
│  ● PSK Reporter Aktiv   ↑47 │
│  ● RBN          Aktiv   ↑12 │
│  ○ APRS-IS      Aus         │
│  ○ Winlink      Aus         │
├──────────────────────────────┤
│  Gesamt: 62 Spots gemeldet   │
└──────────────────────────────┘
```

- `↑3` = Anzahl der hochgeladenen Spots seit Sessionstart
- Tap auf einzelnen Service → direkt zur Reporting-Config in Settings

---

## 5. Datenfluss

```
Audio-Input
    │
    ▼
┌──────────────┐     ┌──────────────────┐
│  Demodulator │────▶│   AppState       │
│  (FT8/JS8/CW)│     │  rxMessages[]    │
└──────────────┘     │  stations[]      │
                     └────────┬─────────┘
                              │ neue Spots
                              ▼
                     ┌──────────────────┐
                     │ ReportingManager │
                     │                  │
                     │  ┌─ WSPRnet  ──┐ │
                     │  ├─ PSK Rep. ──┤ │──── Internet
                     │  ├─ RBN      ──┤ │
                     │  ├─ APRS-IS  ──┤ │
                     │  └─ Winlink  ──┘ │
                     └──────────────────┘
                              │
                              ▼
                     StatusDots-Update (UI)
```

**Wichtig:** Das Reporting läuft **nur wenn Empfang aktiv** ist (`isReceiving == true`).
Es wird **nicht** blockierend ausgeführt — Spots werden in eine Queue geschrieben
und asynchron im Hintergrund übertragen.

---

## 6. Spot-Datenmodell

```swift
/// Universelles Spot-Format für alle Reporter
struct Spot {
    let timestamp: Date
    let mode: DigitalMode          // .ft8, .js8, .cw
    let frequency: Double          // Hz
    let snr: Int                   // dB
    let callsign: String           // Gehörtes Rufzeichen
    let grid: String?              // Locator (falls bekannt)
    let message: String?           // Originaltext
    let drift: Double?             // Nur WSPR
    let wpm: Int?                  // Nur CW

    let receiverCall: String       // Eigenes Rufzeichen
    let receiverGrid: String       // Eigener Locator
    let receiverFrequency: Double  // Dial-Frequenz
}
```

---

## 7. Implementierungsreihenfolge

### Phase 1: Grundgerüst
1. `ReportingService` Protocol definieren
2. `ReportingManager` implementieren
3. `Spot` Datenmodell anlegen
4. Settings-Erweiterung (Toggles + Keychain für Passwörter)
5. Settings-UI Section "Reporting"

### Phase 2: Passwortlose Services (einfachster Einstieg)
6. `PSKReporterService` integrieren (größter Nutzen, kein PW)
7. `WSPRnetReporter` integrieren (wenn WSPR-Decode kommt)
8. `RBNReporter` integrieren (CW-Spots)

### Phase 3: Services mit Credentials
9. `APRSISReporter` integrieren (Passcode, ggf. auto-berechnen)
10. `WinlinkReporter` integrieren (Passwort aus Keychain)

### Phase 4: UI Polish
11. `ReportingStatusDots` in StatusToolbar einbauen
12. Detail-Popover mit Spot-Counter
13. Fehler-Handling und Retry-Logik

---

## 8. Sicherheitsüberlegungen

- **Passwörter** in iOS Keychain speichern, NICHT in `@AppStorage`/UserDefaults
- **APRS-Passcode** kann aus dem Callsign berechnet werden (kein echtes Geheimnis,
  aber trotzdem nicht im Klartext loggen)
- **Rate-Limiting** einbauen — nicht jeden einzelnen Spot sofort senden,
  sondern in Batches (z.B. alle 30 Sekunden für PSK Reporter)
- **Netzwerk-Fehler** graceful behandeln — Spots queuen und bei Reconnect nachsenden
- **Kein Reporting ohne Callsign** — harter Guard, UI disabled

---

## 9. Zusammenfassung

| Was                    | Wo                                  | Aufwand  |
|------------------------|-------------------------------------|----------|
| Protocol + Manager     | `Services/Reporting/`               | Klein    |
| Settings-Toggles       | `Settings.swift`                    | Minimal  |
| Settings-UI            | `SettingsView.swift` (neue Section) | Klein    |
| Spot-Weiterleitung     | `AppState.swift` (3 Stellen)        | Minimal  |
| LED-Dots               | `ContentView.swift` (StatusToolbar) | Klein    |
| Einzelne Reporter      | Je nach API-Komplexität             | Mittel   |

Die Architektur ist bewusst modular gehalten: Jeder Service ist ein eigenständiges
Objekt hinter einem gemeinsamen Protocol. Neue Services können jederzeit hinzugefügt
werden, ohne bestehenden Code zu ändern. Die UI bleibt minimal — ein paar farbige
Punkte in der Toolbar und eine Toggle-Liste in den Settings.
