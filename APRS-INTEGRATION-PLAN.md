# APRS-Integration in DigiFox — Architektur- & Bedienkonzept

## 1. Übersicht

APRS (Automatic Packet Reporting System) ist ein digitales Kommunikationsprotokoll für den
Amateurfunk, das auf VHF/UHF-Frequenzen arbeitet (144.800 MHz Europa, 144.390 MHz Nordamerika).
Es ermöglicht Textnachrichten (bis 67 Zeichen), Positionsmeldungen, Wetterdaten und Telemetrie
über ein Netzwerk aus Digipeatern (Relais).

**Phase 1 (dieses Konzept):** Nachrichten senden und empfangen — kein Kartendisplay.
**Phase 2 (später):** Kartenanzeige mit MapKit, Stationstracking, Wetterdaten.

---

## 2. Technische Unterschiede zu FT8/JS8/CW

| Eigenschaft         | FT8/JS8          | CW              | APRS                          |
|---------------------|------------------|-----------------|-------------------------------|
| Modulation          | 8-FSK            | On/Off-Keying   | Bell 202 AFSK (1200 Baud)    |
| Sample Rate         | 12 kHz           | 12 kHz          | 22.050 oder 44.100 kHz       |
| Bandbreite          | ~50 Hz           | variabel        | ~2.5 kHz (FM-Kanal)          |
| Timing              | Slot-basiert     | Frei            | Asynchron / Event-basiert    |
| Textlänge           | 13 Zeichen       | Unbegrenzt      | 67 Zeichen (Msg), unbegrenzt (Beacon) |
| Protokoll-Stack     | Custom 77-bit    | Morse-Code      | AX.25 Frame-Protokoll        |
| Frequenz            | Variabel pro Band| Variabel        | Fest pro Region (1 Frequenz) |
| Betriebsart (Rig)   | USB              | CW              | FM (Packet)                  |

**Wichtigste Erkenntnis:** APRS verwendet eine fundamental andere Modulationsart (AFSK statt FSK)
und ein etabliertes Rahmenprotokoll (AX.25). Der vorhandene AudioEngine mit 12 kHz Sample Rate
muss für APRS auf mindestens 22.050 kHz erweitert werden können.

---

## 3. Architektur — Modularer Aufbau

### 3.1 Verzeichnisstruktur (analog zu FT8/JS8/CW)

```
DigiFox/
├── Codec/
│   ├── FT8/            ← bestehend
│   ├── JS8/            ← bestehend
│   ├── CW/             ← bestehend
│   ├── WSPR/           ← bestehend (teilweise)
│   └── APRS/           ← NEU
│       ├── APRSProtocol.swift       — Konstanten (Frequenzen, Baudraten, Timing)
│       ├── AFSKModulator.swift      — Bell 202 AFSK Modulator (1200 Baud)
│       ├── AFSKDemodulator.swift    — Bell 202 AFSK Demodulator
│       ├── AX25Frame.swift          — AX.25 Frame-Struktur (Encode/Decode)
│       ├── AX25Codec.swift          — HDLC-Framing (Bit-Stuffing, FCS/CRC-16)
│       └── APRSParser.swift         — APRS-Pakettypen parsen (Position, Message, etc.)
├── Models/
│   ├── BandPlan.swift               ← ERWEITERN (APRS-Frequenzen + Regions-Logik)
│   ├── Message.swift                ← ERWEITERN (APRSMessage Struct)
│   └── APRSTypes.swift              ← NEU (APRS-spezifische Datentypen)
├── Views/
│   └── APRS/            ← NEU
│       ├── APRSMainView.swift       — Hauptansicht (analog zu JS8MainView)
│       ├── APRSMessageListView.swift— Empfangene Nachrichten
│       ├── APRSComposeView.swift    — Nachricht verfassen & senden
│       └── APRSFrequencyView.swift  — Frequenz & Regionsauswahl
└── App/
    ├── AppState.swift               ← ERWEITERN (APRS RX/TX Logik)
    ├── ContentView.swift            ← ERWEITERN (neuer Tab)
    └── Settings.swift               ← ERWEITERN (APRS-Einstellungen)
```

### 3.2 Codec-Schicht: APRS/

Die Codec-Schicht folgt exakt dem Muster der bestehenden Modi:

```
┌─────────────────────────────────────────────────┐
│                APRSProtocol.swift                │
│  Konstanten: Baudrate, Markfreq, Spacefreq,     │
│  Samplerate, APRS-Frequenzen pro Region         │
├─────────────────────────────────────────────────┤
│                                                  │
│  TX-Kette:                                       │
│  APRSMessage → APRSParser.encode()               │
│    → AX25Frame.assemble() → AX25Codec.encode()  │
│      → AFSKModulator.modulate() → [Float]        │
│                                                  │
│  RX-Kette:                                       │
│  [Float] → AFSKDemodulator.demodulate()          │
│    → AX25Codec.decode() → AX25Frame.parse()      │
│      → APRSParser.parse() → APRSMessage          │
│                                                  │
└─────────────────────────────────────────────────┘
```

#### APRSProtocol.swift — Konstanten

```swift
enum APRSProtocol {
    static let baudRate = 1200                    // Bell 202 Standard
    static let markFrequency: Double = 1200.0     // Mark-Ton (Hz)
    static let spaceFrequency: Double = 2200.0    // Space-Ton (Hz)
    static let sampleRate: Double = 22050.0       // Mindestens 2x Space-Frequenz
    static let symbolSamples: Int = Int(sampleRate / Double(baudRate))  // ~18 Samples/Symbol

    // APRS-Standardfrequenzen pro ITU-Region
    static let frequencies: [ITURegion: Double] = [
        .region1: 144_800_000,   // Europa, Afrika
        .region2: 144_390_000,   // Nord-/Südamerika
        .region3: 145_175_000,   // Asien/Pazifik (variiert)
    ]
}
```

#### AFSKModulator.swift — Bell 202 AFSK

```swift
class AFSKModulator {
    /// Erzeugt AFSK-Audiosignal aus HDLC-codierten Bits
    /// Mark = 1200 Hz (logisch 1), Space = 2200 Hz (logisch 0)
    /// NRZI-Codierung: Bitwechsel = Frequenzwechsel
    func modulate(_ bits: [UInt8]) -> [Float]
}
```

#### AFSKDemodulator.swift — Bell 202 AFSK

```swift
class AFSKDemodulator {
    /// Decodiert AFSK-Audio zu digitalen Bits
    /// Methode: Korrelations-Demodulator oder PLL-basiert
    /// Erkennt HDLC-Flags (0x7E) als Frame-Begrenzer
    func demodulate(_ samples: [Float]) -> [AX25Frame]
}
```

#### AX25Frame.swift — Frame-Struktur

```swift
struct AX25Frame {
    let destination: AX25Address     // Ziel-Rufzeichen + SSID
    let source: AX25Address          // Quell-Rufzeichen + SSID
    let digipeaters: [AX25Address]   // Digipeater-Pfad (z.B. WIDE1-1, WIDE2-2)
    let control: UInt8               // 0x03 = UI-Frame
    let pid: UInt8                   // 0xF0 = kein L3-Protokoll
    let information: [UInt8]         // APRS-Nutzdaten

    /// Frame aus Rohdaten zusammenbauen (inkl. HDLC-Flags + Bit-Stuffing)
    func encode() -> [UInt8]

    /// Frame aus empfangenen Bits parsen
    static func decode(_ bits: [UInt8]) -> AX25Frame?
}

struct AX25Address {
    let callsign: String    // Max 6 Zeichen
    let ssid: Int           // 0-15
}
```

#### APRSParser.swift — APRS-Pakettypen

```swift
class APRSParser {
    /// Parse APRS-Information-Field → strukturierte Daten
    static func parse(_ data: [UInt8], from: AX25Address) -> APRSPacket

    /// Erstelle Nachrichten-Paket zum Senden
    static func encodeMessage(to: String, text: String, msgId: Int?) -> [UInt8]

    /// Erstelle Positions-Beacon
    static func encodePosition(lat: Double, lon: Double, symbol: APRSSymbol,
                               comment: String) -> [UInt8]
}
```

### 3.3 Datenmodell-Erweiterungen

#### APRSTypes.swift — Neue Typen

```swift
/// APRS-Pakettyp (Data Type Identifier)
enum APRSPacketType: String {
    case position      // ! / = (ohne Zeitstempel) oder / @ (mit Zeitstempel)
    case message       // :
    case weather       // _ oder aus Position
    case telemetry     // T
    case status        // >
    case beacon        // Periodische Positions-/Status-Meldung
    case object        // ;
    case item          // )
    case micE          // ` oder ' (Mic-E compressed position)
}

/// Geparste APRS-Nachricht
struct APRSPacket: Identifiable {
    let id = UUID()
    let timestamp: Date
    let from: AX25Address
    let to: AX25Address
    let via: [AX25Address]          // Digipeater-Pfad
    let type: APRSPacketType
    let raw: String                  // Rohtext für Debug

    // Positions-Daten (optional)
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?            // Meter
    var course: Int?                 // Grad
    var speed: Double?               // km/h
    var symbol: APRSSymbol?

    // Nachrichten-Daten (optional)
    var messageText: String?
    var messageAddressee: String?    // Empfänger-Rufzeichen
    var messageId: String?           // Für ACK-Tracking
    var isAck: Bool = false          // Ist dies eine Bestätigung?

    // Wetter-Daten (optional, Phase 2)
    var weather: APRSWeather?
}

/// APRS-Symbol (Tabelle + Code)
struct APRSSymbol {
    let table: Character    // '/' = primär, '\\' = alternativ
    let code: Character     // z.B. '-' = Haus, '>' = Auto
}

/// APRS-Wetter (Phase 2)
struct APRSWeather {
    var windDirection: Int?
    var windSpeed: Double?
    var temperature: Double?
    var humidity: Int?
    var pressure: Double?
}
```

#### Message.swift — Erweiterung

```swift
// Bestehender RxMessage bekommt optional APRS-Daten:
struct RxMessage: Identifiable, Equatable {
    // ... bestehende Felder ...

    // APRS-spezifisch (NEU)
    var aprsPacket: APRSPacket?
    var isAPRSMessage: Bool { aprsPacket?.type == .message }
    var isAPRSAck: Bool { aprsPacket?.isAck == true }
}
```

### 3.4 BandPlan-Verallgemeinerung

Die zentrale Änderung: Der BandPlan wird so erweitert, dass er APRS-Frequenzen kennt und
regionsabhängig die richtige Frequenz liefert.

```swift
// BandPlan.swift — Erweiterungen

struct BandPlan {
    // ... bestehende HF/VHF/UHF-Bänder bleiben ...

    // MARK: - APRS Frequenzen (NEU)

    /// APRS-Frequenzen sind fest pro ITU-Region, nicht pro Band wählbar
    static let aprsFrequencies: [String: Double] = [
        "2m":   144_800_000,     // Region 1 Default (Europa)
        "70cm": 430_512_500,     // APRS auf 70cm (selten)
    ]

    /// APRS-Frequenz nach Region (die eigentlich relevante Methode)
    static func aprsFrequency(for region: ITURegion) -> Double {
        switch region {
        case .region1: return 144_800_000
        case .region2: return 144_390_000
        case .region3: return 145_175_000
        }
    }

    // MARK: - Verallgemeinerte Frequenz-Abfrage (REFACTORING)

    /// dialFrequency() erweitert um .aprs
    static func dialFrequency(band: String, mode: DigitalMode) -> Double? {
        switch mode {
        case .ft8:  return ft8Frequencies[band]
        case .js8:  return js8Frequencies[band]
        case .cw:   return cwFrequencies[band]
        case .aprs: return aprsFrequencies[band]
        }
    }

    /// availableBands() erweitert um .aprs
    static func availableBands(for mode: DigitalMode) -> [Band] {
        allBands.filter { band in
            switch mode {
            case .ft8:  return ft8Frequencies[band.id] != nil
            case .js8:  return js8Frequencies[band.id] != nil
            case .cw:   return cwFrequencies[band.id] != nil
            case .aprs: return aprsFrequencies[band.id] != nil
            }
        }
    }
}
```

**Wichtig:** Für APRS ist die Band-Auswahl eigentlich nachrangig — man wählt primär die
ITU-Region (Europa/Amerika/Asien), und die Frequenz steht dann fest. Das unterscheidet sich
von FT8/JS8, wo man das Band frei wählt. Das UI sollte dies berücksichtigen.

---

## 4. DigitalMode-Erweiterung

```swift
enum DigitalMode: Int, CaseIterable, Identifiable {
    case ft8  = 0
    case js8  = 1
    case cw   = 4
    case aprs = 5     // NEU
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .ft8:  return "FT8"
        case .js8:  return "JS8Call"
        case .cw:   return "CW"
        case .aprs: return "APRS"
        }
    }
}
```

---

## 5. Bedienkonzept (UX)

### 5.1 Tab-Integration

APRS wird als eigener Tab in die bestehende TabView eingefügt — konsistent mit FT8, JS8, CW:

```
┌──────┬──────────┬────┬──────┬──────────┬──────────────┐
│ FT8  │ JS8Call   │ CW │ APRS │ Aktivität│ Einstellungen│
└──────┴──────────┴────┴──────┴──────────┴──────────────┘
```

### 5.2 APRS-Hauptansicht (APRSMainView)

Die Ansicht folgt dem Muster von JS8MainView — Nachrichten-zentriert, kein Wasserfall
(APRS-Pakete sind zu kurz für sinnvolle Spektrumdarstellung):

```
┌─────────────────────────────────────────────────────┐
│  APRS                           [Callsign] [Status] │  ← NavigationBar + StatusToolbar
├─────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────┐│
│  │  144.800 MHz (Region 1 — Europa)          [▼]  ││  ← Frequenz + Region-Picker
│  └─────────────────────────────────────────────────┘│
├─────────────────────────────────────────────────────┤
│                                                      │
│  ┌──────────┬──────────┐                             │
│  │ Alle     │ An mich  │                             │  ← Segmented Filter
│  └──────────┴──────────┘                             │
│                                                      │
│  12:34  DL1ABC>APRS  via WIDE1-1                    │  ← Empfangene Pakete
│  📍 Position: JO31lk (52.123, 13.456)               │
│                                                      │
│  12:33  OE3XYZ>DL1ABC                               │
│  💬 "Hallo, bist du QRV auf 2m?"          [ACK ✓]   │
│                                                      │
│  12:30  DB0ABC>APRS  via WIDE2-2                    │
│  📍 Position: JN48 — Digipeater                      │
│                                                      │
│  12:28  HB9ZZZ>APRS                                 │
│  📡 Status: "Portable auf dem Feldberg"              │
│                                                      │
├─────────────────────────────────────────────────────┤
│  ┌───────────────────────────────────┐               │
│  │ An: [DL1ABC     ▼]               │               │  ← Empfänger (Callsign)
│  ├───────────────────────────────────┤               │
│  │ Nachricht...                 [➤] │               │  ← Eingabefeld + Senden
│  └───────────────────────────────────┘               │
│  67/67 Zeichen                                       │  ← Zeichenzähler
└─────────────────────────────────────────────────────┘
```

### 5.3 Detail-Beschreibung der UI-Elemente

#### Frequenz-/Regionsanzeige (APRSFrequencyView)

Anders als bei FT8/JS8 gibt es bei APRS keine Band-Auswahl — die Frequenz ergibt sich
aus der ITU-Region. Ein einfacher Picker genügt:

```swift
Picker("Region", selection: $settings.ituRegion) {
    Text("Region 1 — 144.800 MHz").tag(ITURegion.region1)
    Text("Region 2 — 144.390 MHz").tag(ITURegion.region2)
    Text("Region 3 — 145.175 MHz").tag(ITURegion.region3)
}
```

Die Frequenz wird automatisch gesetzt. Kein manueller TX-Offset nötig (APRS läuft auf FM,
nicht USB).

#### Nachrichtenliste (APRSMessageListView)

- **Filterung:** Segmented Control "Alle" / "An mich" — filtert nach eigenen Callsign als
  Addressee
- **Pakettyp-Icons:** Visuell unterscheidbar durch SF Symbols:
  - 📍 `mappin` — Position
  - 💬 `message` — Textnachricht
  - 📡 `antenna.radiowaves.left.and.right` — Status/Beacon
  - ☁️ `cloud` — Wetter (Phase 2)
- **ACK-Status:** Gesendete Nachrichten zeigen Zustellbestätigung (✓ / ausstehend)
- **Digipeater-Pfad:** Anzeige "via WIDE1-1" zeigt den Relay-Pfad

#### Nachricht verfassen (APRSComposeView)

- **An-Feld:** Callsign des Empfängers (Autocomplete aus empfangenen Stationen)
- **Nachrichtenfeld:** Max. 67 Zeichen mit Live-Zähler
- **Sende-Button:** Deaktiviert wenn leer oder kein Callsign
- **Message-ID:** Automatisch vergeben für ACK-Tracking

### 5.4 Einstellungen (SettingsView-Erweiterung)

```
┌─ APRS-Einstellungen ────────────────────────────────┐
│                                                      │
│  ITU-Region:        [Region 1 (Europa)      ▼]      │
│  Digipeater-Pfad:   [WIDE1-1,WIDE2-1        ]      │
│  Beacon aktivieren: [○ Aus]                          │
│  Beacon-Intervall:  [10 Minuten             ▼]      │
│  APRS-Symbol:       [/- Station/Haus        ▼]      │
│  APRS-Kommentar:    [DigiFox iOS             ]      │
│                                                      │
└─────────────────────────────────────────────────────┘
```

---

## 6. AppState-Erweiterungen

### 6.1 Neue State-Variablen

```swift
@MainActor
class AppState: ObservableObject {
    // ... bestehende State-Variablen ...

    // MARK: - APRS State (NEU)
    @Published var aprsMessages = [APRSPacket]()        // Empfangene APRS-Pakete
    @Published var aprsPendingAcks = [String: Date]()   // MsgID → Zeitpunkt (auf ACK wartend)
    @Published var aprsDecoding = false
    @Published var aprsTxMessage = ""                   // Aktueller TX-Text
    @Published var aprsTxAddressee = ""                 // Empfänger-Callsign

    // Neue Codec-Instanzen
    private let afskModulator = AFSKModulator()
    private let afskDemodulator = AFSKDemodulator()
    private var aprsMessageCounter = 0                  // Für Message-IDs
}
```

### 6.2 Neue Methoden

```swift
extension AppState {
    // MARK: - APRS RX

    /// Starte APRS-Dekodierung (analog zu startCWDecodeLoop)
    func startAPRSDecodeLoop() {
        aprsDecoding = true
        demodTask = Task { [weak self] in
            while !Task.isCancelled {
                // APRS ist asynchron — kurze Polling-Intervalle
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                await self?.processAPRSAudio()
            }
        }
    }

    private func processAPRSAudio() {
        let samples = audioEngine.getBufferedSamples()
        guard !samples.isEmpty else { return }
        let frames = afskDemodulator.demodulate(samples)
        for frame in frames {
            if let packet = APRSParser.parse(frame) {
                aprsMessages.insert(packet, at: 0)
                if aprsMessages.count > 500 { aprsMessages.removeLast() }
                handleAPRSPacket(packet)
            }
        }
        audioEngine.clearBuffer()
    }

    private func handleAPRSPacket(_ packet: APRSPacket) {
        // ACK empfangen? → aus pendingAcks entfernen
        if packet.isAck, let msgId = packet.messageId {
            aprsPendingAcks.removeValue(forKey: msgId)
        }
        // Nachricht an mich? → Auto-ACK senden
        if packet.type == .message,
           packet.messageAddressee?.uppercased() == settings.callsign.uppercased(),
           let msgId = packet.messageId {
            sendAPRSAck(to: packet.from.callsign, msgId: msgId)
        }
    }

    // MARK: - APRS TX

    func transmitAPRSMessage() {
        guard !aprsTxMessage.isEmpty, !aprsTxAddressee.isEmpty else { return }
        aprsMessageCounter += 1
        let msgId = String(aprsMessageCounter)

        let payload = APRSParser.encodeMessage(
            to: aprsTxAddressee,
            text: aprsTxMessage,
            msgId: aprsMessageCounter
        )
        let frame = AX25Frame(
            destination: AX25Address(callsign: "APRS", ssid: 0),
            source: AX25Address(callsign: settings.callsign, ssid: 0),
            digipeaters: settings.aprsDigipeaterPath,
            control: 0x03, pid: 0xF0,
            information: payload
        )
        let bits = AX25Codec.encode(frame)
        let samples = afskModulator.modulate(bits)

        aprsPendingAcks[msgId] = Date()
        statusText = "APRS: Sende an \(aprsTxAddressee)..."

        // TX über Rig (FM-Modus) — PTT-Steuerung wie bei CW
        transmitAPRSAudio(samples)
    }

    private func sendAPRSAck(to callsign: String, msgId: String) {
        // Automatische Bestätigung senden
        let payload = APRSParser.encodeAck(to: callsign, msgId: msgId)
        let frame = AX25Frame(/* ... */)
        let bits = AX25Codec.encode(frame)
        let samples = afskModulator.modulate(bits)
        transmitAPRSAudio(samples)
    }

    private func transmitAPRSAudio(_ samples: [Float]) {
        // Rig auf FM umschalten, PTT ein, Audio senden, PTT aus
        // Analog zu transmitFT8/transmitJS8/sendCW
    }
}
```

### 6.3 switchMode-Erweiterung

```swift
func switchMode(_ mode: DigitalMode) {
    // ... bestehende Logik ...
    switch mode {
    case .ft8:  startFT8Cycle()
    case .js8:  startJS8DemodLoop()
    case .cw:   startCWDecodeLoop()
    case .aprs: startAPRSDecodeLoop()   // NEU
    }

    // APRS braucht FM statt USB
    if mode == .aprs {
        let rigMode = "FM"
        Task { try? await catController.setMode(rigMode) }
    }
}
```

---

## 7. AudioEngine-Anpassungen

### 7.1 Problem: Sample Rate

Die bestehende AudioEngine arbeitet mit 12 kHz. APRS benötigt mindestens 22.050 kHz
(Nyquist für den 2200 Hz Space-Ton).

### 7.2 Lösung: Konfigurierbare Sample Rate

```swift
class AudioEngine {
    // NEU: Modus-abhängige Sample Rate
    var targetSampleRate: Double = 12000

    /// Setze Sample Rate passend zum Modus
    func configure(for mode: DigitalMode) {
        switch mode {
        case .ft8, .js8, .cw:
            targetSampleRate = 12000
        case .aprs:
            targetSampleRate = 22050
        }
        // Audio-Session neu konfigurieren falls nötig
    }
}
```

**Alternative:** Der AFSKDemodulator könnte auch bei 12 kHz arbeiten (2200 Hz < Nyquist 6 kHz),
allerdings wäre die Abtastung für den Space-Ton sehr grob (~5.5 Samples pro Periode).
Empfehlung: 22.050 kHz für robustere Demodulation.

**TruSDX-Sonderfall:** Die TruSDX-Serielle Audio-Schnittstelle liefert Samples bei ~8 kHz.
Für APRS über TruSDX müsste geprüft werden, ob das Gerät FM unterstützt und AFSK-Signale
korrekt durchleiten kann. Wahrscheinlich ist ein separates VHF-Funkgerät für APRS sinnvoller.

---

## 8. Hardware-Überlegungen

### 8.1 Radio-Profil-Erweiterung

APRS läuft typischerweise auf VHF-FM-Handgeräten (Baofeng, Yaesu FT-65, Kenwood TH-D74, etc.)
die über ein Audio-Kabel (Digirig oder VOX) angeschlossen werden.

```swift
enum RadioProfile: String, CaseIterable, Identifiable {
    case digirig = "Digirig"
    case trusdx  = "(tr)uSDX"
    case aprsVHF = "VHF/APRS"    // NEU — generischer VHF-Handfunke + Kabel

    var supportsAPRS: Bool {
        switch self {
        case .digirig: return true   // Digirig kann auch VHF-Handgeräte anschließen
        case .trusdx:  return false  // TruSDX ist HF-only
        case .aprsVHF: return true
        }
    }
}
```

### 8.2 PTT-Steuerung für APRS

- **Digirig:** RTS/DTR-Signal über USB-Serial → PTT-Ausgang
- **VOX:** Audio-Signal triggert automatisch PTT
- **CAT:** Hamlib `setPTT()` falls das VHF-Gerät CAT unterstützt

---

## 9. Settings-Erweiterung

```swift
class AppSettings: ObservableObject {
    // ... bestehende Settings ...

    // MARK: - APRS Settings (NEU)
    @AppStorage("ituRegion") var ituRegionRaw: String = ITURegion.region1.rawValue
    @AppStorage("aprsDigipeaterPath") var aprsDigipeaterPathRaw: String = "WIDE1-1,WIDE2-1"
    @AppStorage("aprsBeaconEnabled") var aprsBeaconEnabled: Bool = false
    @AppStorage("aprsBeaconInterval") var aprsBeaconInterval: Int = 600  // Sekunden
    @AppStorage("aprsSymbolTable") var aprsSymbolTable: String = "/"
    @AppStorage("aprsSymbolCode") var aprsSymbolCode: String = "-"  // Haus
    @AppStorage("aprsComment") var aprsComment: String = "DigiFox iOS"
    @AppStorage("aprsSSID") var aprsSSID: Int = 7  // 7 = Handfunkgerät

    var ituRegion: ITURegion {
        get { ITURegion(rawValue: ituRegionRaw) ?? .region1 }
        set { ituRegionRaw = newValue.rawValue }
    }

    var aprsDigipeaterPath: [AX25Address] {
        aprsDigipeaterPathRaw.split(separator: ",").map {
            let parts = $0.split(separator: "-")
            return AX25Address(
                callsign: String(parts[0]),
                ssid: parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            )
        }
    }
}
```

---

## 10. ContentView-Erweiterung

```swift
struct ContentView: View {
    var body: some View {
        TabView(selection: $selectedTab) {
            FT8MainView()
                .tabItem { Label("FT8", systemImage: "waveform.path") }
                .tag(0)
            JS8MainView()
                .tabItem { Label("JS8Call", systemImage: "text.bubble") }
                .tag(1)
            CWView()
                .tabItem { Label("CW", systemImage: "dot.radiowaves.right") }
                .tag(4)
            APRSMainView()                                                // NEU
                .tabItem { Label("APRS", systemImage: "paperplane") }    // NEU
                .tag(5)                                                   // NEU
            ActivityView()
                .tabItem { Label("Aktivität", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gear") }
                .tag(3)
        }
    }
}
```

---

## 11. Implementierungsreihenfolge (Phasen)

### Phase 1a — Grundlagen (Codec-Schicht)
1. `APRSProtocol.swift` — Konstanten definieren
2. `AX25Frame.swift` + `AX25Codec.swift` — Frame-Format und HDLC-Codierung
3. `AFSKModulator.swift` — Bell 202 AFSK Modulator (TX)
4. `AFSKDemodulator.swift` — Bell 202 AFSK Demodulator (RX)
5. `APRSParser.swift` — APRS-Pakete parsen und erzeugen
6. Unit-Tests für alle Codec-Komponenten

### Phase 1b — Integration (App-Schicht)
7. `DigitalMode.aprs` hinzufügen
8. `BandPlan.swift` erweitern (APRS-Frequenzen)
9. `APRSTypes.swift` — Datenmodell
10. `AppState.swift` erweitern (APRS RX/TX Methoden)
11. `AppSettings.swift` erweitern (APRS-Settings)
12. AudioEngine Sample-Rate Konfiguration

### Phase 1c — UI
13. `APRSMainView.swift` — Hauptansicht
14. `APRSMessageListView.swift` — Nachrichtenliste
15. `APRSComposeView.swift` — Nachricht verfassen
16. `APRSFrequencyView.swift` — Frequenz/Region
17. `ContentView.swift` — neuer Tab
18. `SettingsView.swift` — APRS-Einstellungen

### Phase 2 (Zukunft)
19. Karten-Integration (MapKit) für Stationspositionen
20. Wetter-Datenanzeige
21. Beacon-Funktion (periodische Positionsmeldungen)
22. Objekt-/Item-Tracking
23. Digipeater-Visualisierung

---

## 12. Zusammenfassung der Änderungen an bestehenden Dateien

| Datei                | Änderung                                              |
|----------------------|------------------------------------------------------|
| `AppState.swift`     | + DigitalMode.aprs Case, + APRS State-Variablen, + APRS RX/TX Methoden, + switchMode erweitern |
| `BandPlan.swift`     | + aprsFrequencies Dictionary, + aprsFrequency(for:) Methode, switch-Cases in dialFrequency/availableBands erweitern |
| `Message.swift`      | + aprsPacket Property in RxMessage (optional)         |
| `Settings.swift`     | + ITU Region, Digipeater-Pfad, Beacon-Settings, SSID |
| `ContentView.swift`  | + APRS Tab (.tag(5))                                  |
| `SettingsView.swift` | + APRS-Sektion in den Einstellungen                  |
| `AudioEngine.swift`  | + Konfigurierbare Sample Rate (12kHz ↔ 22kHz)        |
| `RadioProfile.swift` | + Optional: VHF/APRS Profil                          |

| Neue Dateien                        | Zweck                            |
|-------------------------------------|----------------------------------|
| `Codec/APRS/APRSProtocol.swift`    | Konstanten                       |
| `Codec/APRS/AFSKModulator.swift`   | Bell 202 AFSK TX                 |
| `Codec/APRS/AFSKDemodulator.swift` | Bell 202 AFSK RX                 |
| `Codec/APRS/AX25Frame.swift`       | AX.25 Rahmenformat               |
| `Codec/APRS/AX25Codec.swift`       | HDLC Bit-Stuffing + CRC-16      |
| `Codec/APRS/APRSParser.swift`      | APRS-Datenfeld Parser/Encoder   |
| `Models/APRSTypes.swift`           | APRSPacket, APRSSymbol, etc.    |
| `Views/APRS/APRSMainView.swift`    | Hauptansicht                     |
| `Views/APRS/APRSMessageListView.swift` | Nachrichtenliste             |
| `Views/APRS/APRSComposeView.swift` | Nachricht verfassen              |
| `Views/APRS/APRSFrequencyView.swift`| Frequenz/Region-Anzeige         |

---

## 13. Offene Fragen / Entscheidungen

1. **Sample Rate:** 12 kHz beibehalten (funktioniert gerade noch) oder auf 22 kHz wechseln
   für robustere AFSK-Demodulation?
2. **TruSDX-Kompatibilität:** TruSDX ist ein reiner HF-Transceiver — APRS würde ein
   separates VHF-Gerät erfordern. Soll ein zweites RadioProfile dafür angelegt werden?
3. **Gleichzeitiger Betrieb:** Soll man gleichzeitig FT8 auf HF und APRS auf VHF empfangen
   können (zwei getrennte Audio-Eingänge)? Oder ist nur ein Modus gleichzeitig aktiv?
4. **APRS-IS Gateway:** Soll zusätzlich APRS über Internet (APRS-IS TCP-Verbindung)
   unterstützt werden, als Alternative zum Funkweg?
5. **9600 Baud:** Soll neben dem klassischen 1200 Baud AFSK auch 9600 Baud GFSK
   (für moderne Geräte auf 70cm) unterstützt werden?
