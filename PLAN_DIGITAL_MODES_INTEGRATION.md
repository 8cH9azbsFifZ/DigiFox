# DigiFox — Integrationsplan: Alle Digitalen Betriebsarten aus Fldigi & WSJT-X

## 1. Ausgangslage

### 1.1 DigiFox heute
- **Plattform:** iOS 17+ (Swift / SwiftUI)
- **Bereits implementiert:** FT8, JS8Call, CW/Morse, WSPR (TX-only)
- **Audio:** AVAudioEngine + Accelerate-FFT, 12 kHz Sampling
- **Hardware:** Digirig (USB-Audio), (tr)uSDX (serielles Audio), Hamlib CAT
- **Architektur:** Modulares Codec-Verzeichnis (`Codec/FT8/`, `Codec/JS8/`, `Codec/CW/`, `Codec/WSPR/`)
- **DSP:** Eigene Swift-Implementierungen + C/C++-Bibliotheken (ggmorse)

### 1.2 Zu integrierende Modi

#### Aus WSJT-X (GPLv3, C++/Fortran)
| Modus | Typ | Bandbreite | Zyklus | Einsatz |
|-------|-----|-----------|--------|---------|
| **FT4** | 4-GFSK | ~90 Hz | 7,5 s | Contest, schnelle QSOs |
| **JT65** | 65-FSK | ~177 Hz | 60 s | EME, Schwachsignal HF |
| **JT9** | 9-FSK | ~16 Hz | 60 s | Schwachsignal HF, schmalbandig |
| **JT4** | 4-FSK | variabel | 60 s | EME Mikrowelle |
| **Q65** | 65-FSK | variabel | 15–300 s | Schwachsignal, Troposcatter |
| **FST4** | 4-GFSK | ~16 Hz | 15–1800 s | LF/MF-Bänder |
| **FST4W** | 4-GFSK | ~16 Hz | 120–1800 s | LF/MF Baken |
| **MSK144** | MSK | ~2,4 kHz | 5/10/15 s | Meteorscatter |
| **Echo** | CW | – | – | EME-Echotest |

**Bereits in DigiFox:** FT8, WSPR
**Noch fehlend:** FT4, JT65, JT9, JT4, Q65, FST4, FST4W, MSK144, Echo

#### Aus Fldigi (GPLv3+, C++)
| Modus | Typ | Bandbreite | Einsatz |
|-------|-----|-----------|---------|
| **PSK31** | BPSK | 31 Hz | Keyboard-QSO, beliebtester PSK |
| **PSK63** | BPSK | 63 Hz | Schnellerer PSK |
| **PSK125/250/500** | BPSK | 125–500 Hz | Daten, schneller Text |
| **QPSK31/63** | QPSK | 31–63 Hz | PSK mit FEC |
| **PSK-R (125/250/500)** | PSK + FEC | 125–500 Hz | Robuste PSK-Varianten |
| **RTTY** | FSK (Baudot) | ~250 Hz | Klassischer Fernschreiber |
| **Olivia 8/250–32/1000** | MFSK | 250–1000 Hz | Robuster Chat, EMCOMM |
| **Contestia** | MFSK | 250–1000 Hz | Contest-Variante von Olivia |
| **MT63 (500/1000/2000)** | OFDM-ähnlich | 500–2000 Hz | Robust, breitbandig |
| **MFSK4–MFSK64** | MFSK | variabel | MFSK-Familie |
| **DominoEX (4–22)** | IFK+ | variabel | IFK-basiert, drift-tolerant |
| **Thor (4–22)** | IFK+ | variabel | DominoEX mit FEC |
| **Throb / ThrobX** | Differentiell | 72–288 Hz | Experimentell |
| **Hellschreiber** | On-Off | ~400 Hz | Feld-Hell, Fax-Hell etc. |
| **IFKP** | IFK+ | variabel | Weak-Signal Chat |
| **FSQ** | MFSK | ~360 Hz | Fast Simple QSO |
| **Navtex/SITOR-B** | ARQ | ~250 Hz | Maritime Nachrichten |
| **Weather FAX** | Faksimile | ~2,8 kHz | Wetterkarten |

---

## 2. Lizenz-Strategie

### 2.1 Lizenz-Kompatibilität
| Projekt | Lizenz | Kompatibel? |
|---------|--------|-------------|
| Fldigi | GPLv3+ | Ja, aber: GPL-Code muss als **separate dynamische Bibliothek** oder **Prozess** eingebunden werden, wenn DigiFox nicht vollständig GPL sein soll |
| WSJT-X | GPLv3 | Gleiche Einschränkung |
| ft8_lib (kgoba) | MIT | Frei integrierbar |
| ggmorse | MIT | Bereits integriert |

### 2.2 Empfohlener Ansatz
**Option A (Empfohlen): Eigenständige Swift/C-Reimplementierung der Algorithmen**
- Die mathematischen Algorithmen (PSK-Modulation, FSK, MFSK, Viterbi-Decoder, LDPC) sind **nicht urheberrechtlich schützbar** — nur die konkrete Code-Implementierung
- Die Protokollspezifikationen sind öffentlich dokumentiert
- DigiFox hat bereits bewiesene Fähigkeit, Codecs in Swift zu implementieren (FT8, JS8)
- Vorteil: Keine GPL-Infektion, volle Kontrolle, optimiert für iOS/ARM

**Option B: GPL-Bibliotheken als eingebettete C-Submodule**
- Fldigi-Modemcode und WSJT-X Fortran-Libs als statische Bibliotheken einbetten
- DigiFox müsste dann selbst GPL werden
- Vorteil: Schnellere Erstintegration

**Empfehlung:** Option A für die Fldigi-Modi (PSK, RTTY, Olivia etc. sind algorithmisch gut dokumentiert). Für die komplexeren WSJT-X-Modi (Q65, FST4) könnte man die bestehende FT8-Implementierung als Ausgangspunkt nutzen, da viele WSJT-X-Modi denselben 77-Bit-Nachrichtenrahmen teilen.

---

## 3. Architektur-Entwurf

### 3.1 Modem-Abstraktionsschicht (Kern der Erweiterung)

```
┌──────────────────────────────────────────────────────────┐
│                    DigitalModem Protocol                  │
│  (Swift Protocol — gemeinsames Interface für alle Modi)  │
├──────────────────────────────────────────────────────────┤
│  func configure(_ params: ModemParameters)               │
│  func modulateSamples(message: String) -> [Float]        │
│  func feedSamples(_ samples: [Float], count: Int)        │
│  var onMessageDecoded: ((DecodedMessage) -> Void)?       │
│  var modemInfo: ModemInfo { get }                        │
│  var supportedBandwidths: [Float] { get }                │
│  var requiresTimeSyncronization: Bool { get }            │
└──────────────────────────────────────────────────────────┘
         ▲              ▲               ▲              ▲
         │              │               │              │
    ┌────┴────┐   ┌────┴────┐    ┌────┴────┐    ┌───┴────┐
    │PSKModem │   │RTTYModem│    │OliviaM. │    │FT4Modem│
    │(Fldigi) │   │(Fldigi) │    │(Fldigi) │    │(WSJT-X)│
    └─────────┘   └─────────┘    └─────────┘    └────────┘
```

### 3.2 Verzeichnisstruktur (Erweiterung)

```
DigiFox/
├── Codec/
│   ├── Common/                          ← NEU: Gemeinsame DSP-Bausteine
│   │   ├── DigitalModemProtocol.swift   ← Das gemeinsame Interface
│   │   ├── ModemParameters.swift        ← Konfigurationsmodell
│   │   ├── DecodedMessage.swift         ← Einheitliches Nachrichten-Modell
│   │   ├── ModemRegistry.swift          ← Registry aller verfügbaren Modi
│   │   ├── DSP/
│   │   │   ├── PSKEngine.swift          ← BPSK/QPSK Mod/Demod Kern
│   │   │   ├── FSKEngine.swift          ← FSK-Grundbaustein
│   │   │   ├── MFSKEngine.swift         ← Multi-FSK Grundbaustein
│   │   │   ├── VaricodeTable.swift      ← Varicode (für PSK31 etc.)
│   │   │   ├── BaudotTable.swift        ← Baudot-Code (für RTTY)
│   │   │   ├── ConvolutionalCodec.swift ← Faltungscode (Viterbi)
│   │   │   ├── LDPCCodec.swift          ← Refactored aus FT8LDPC
│   │   │   ├── ReedSolomon.swift        ← Reed-Solomon (JT65)
│   │   │   ├── CRCEngine.swift          ← Generischer CRC
│   │   │   ├── InterleaverEngine.swift  ← Bit/Symbol-Interleaving
│   │   │   ├── GrayCode.swift           ← Gray-Codierung
│   │   │   ├── CostasSync.swift         ← Refactored Costas-Sync
│   │   │   └── GFSKModulator.swift      ← GFSK (für FT4, FST4)
│   │   └── MessagePack77.swift          ← Gemeinsamer 77-Bit WSJT-X Packer
│   │
│   ├── FT8/            (besteht bereits)
│   ├── JS8/            (besteht bereits)
│   ├── CW/             (besteht bereits)
│   ├── WSPR/           (besteht bereits)
│   │
│   ├── FT4/                             ← NEU
│   │   ├── FT4Protocol.swift
│   │   ├── FT4Modulator.swift
│   │   └── FT4Demodulator.swift
│   │
│   ├── JT65/                            ← NEU
│   │   ├── JT65Protocol.swift
│   │   ├── JT65Modulator.swift
│   │   └── JT65Demodulator.swift
│   │
│   ├── JT9/                             ← NEU
│   │   ├── JT9Protocol.swift
│   │   ├── JT9Modulator.swift
│   │   └── JT9Demodulator.swift
│   │
│   ├── Q65/                             ← NEU
│   │   ├── Q65Protocol.swift
│   │   ├── Q65Modulator.swift
│   │   └── Q65Demodulator.swift
│   │
│   ├── FST4/                            ← NEU
│   │   ├── FST4Protocol.swift
│   │   ├── FST4Modulator.swift
│   │   └── FST4Demodulator.swift
│   │
│   ├── MSK144/                          ← NEU
│   │   ├── MSK144Protocol.swift
│   │   ├── MSK144Modulator.swift
│   │   └── MSK144Demodulator.swift
│   │
│   ├── PSK/                             ← NEU (Fldigi-Familie)
│   │   ├── PSKProtocol.swift            ← PSK31/63/125/250/500
│   │   ├── PSKModulator.swift
│   │   ├── PSKDemodulator.swift
│   │   └── QPSKVariant.swift
│   │
│   ├── RTTY/                            ← NEU
│   │   ├── RTTYProtocol.swift
│   │   ├── RTTYModulator.swift
│   │   └── RTTYDemodulator.swift
│   │
│   ├── Olivia/                          ← NEU
│   │   ├── OliviaProtocol.swift
│   │   ├── OliviaModulator.swift
│   │   └── OliviaDemodulator.swift
│   │
│   ├── MT63/                            ← NEU
│   │   ├── MT63Protocol.swift
│   │   ├── MT63Modulator.swift
│   │   └── MT63Demodulator.swift
│   │
│   ├── MFSK/                            ← NEU (MFSK4–64 Familie)
│   │   ├── MFSKProtocol.swift
│   │   ├── MFSKModulator.swift
│   │   └── MFSKDemodulator.swift
│   │
│   ├── DominoEX/                        ← NEU
│   │   ├── DominoEXProtocol.swift
│   │   ├── DominoEXModulator.swift
│   │   └── DominoEXDemodulator.swift
│   │
│   ├── Thor/                            ← NEU
│   │   ├── ThorProtocol.swift
│   │   ├── ThorModulator.swift
│   │   └── ThorDemodulator.swift
│   │
│   ├── Hellschreiber/                   ← NEU
│   │   ├── HellProtocol.swift
│   │   ├── HellModulator.swift
│   │   └── HellDemodulator.swift
│   │
│   ├── FSQ/                             ← NEU
│   │   ├── FSQProtocol.swift
│   │   ├── FSQModulator.swift
│   │   └── FSQDemodulator.swift
│   │
│   └── IFKP/                            ← NEU
│       ├── IFKPProtocol.swift
│       ├── IFKPModulator.swift
│       └── IFKPDemodulator.swift
│
├── Views/
│   ├── ContentView.swift                ← Erweitert um Mode-Picker
│   ├── ModePicker/                      ← NEU
│   │   ├── ModePickerView.swift
│   │   ├── ModeCategoryView.swift
│   │   └── ModeDetailCard.swift
│   ├── GenericModem/                    ← NEU: Wiederverwendbare Views
│   │   ├── TextTerminalView.swift       ← Für PSK, RTTY, Olivia etc.
│   │   ├── TimedDecodeView.swift        ← Für FT4, JT65, JT9 etc.
│   │   └── SpectrumScopeView.swift      ← Erweiterbares Spektrum
│   ├── FT8/             (besteht)
│   ├── JS8/             (besteht)
│   └── CW/              (besteht)
│
└── Audio/
    └── AudioEngine.swift                ← Erweitert: variable Samplerate
```

### 3.3 Das DigitalModem-Protocol (Swift)

```swift
/// Einheitliches Interface für alle digitalen Betriebsarten
protocol DigitalModem: AnyObject {

    // MARK: - Identifikation
    var modemInfo: ModemInfo { get }

    // MARK: - Konfiguration
    func configure(_ params: ModemParameters)

    // MARK: - Modulation (TX)
    /// Erzeugt Audio-Samples für eine Nachricht
    func modulate(message: String, frequency: Double) -> [Float]

    // MARK: - Demodulation (RX)
    /// Füttert Audio-Samples in den Decoder
    func feedSamples(_ samples: [Float], sampleRate: Double)

    // MARK: - Callbacks
    var onMessageDecoded: ((DecodedMessage) -> Void)? { get set }
    var onSpectrumUpdate: (([Float]) -> Void)? { get set }

    // MARK: - Lifecycle
    func start()
    func stop()
    func reset()
}

struct ModemInfo {
    let id: String                    // z.B. "psk31", "ft4", "olivia-8-250"
    let displayName: String           // z.B. "PSK31", "FT4"
    let category: ModemCategory       // .wsjt, .psk, .mfsk, .fsk, .other
    let bandwidth: ClosedRange<Float> // z.B. 31...31 oder 250...1000
    let isTimeSynchronized: Bool      // true für FT8/FT4/JT65 etc.
    let isKeyboardMode: Bool          // true für PSK31, RTTY etc.
    let sampleRate: Double            // Benötigte Abtastrate
    let origin: ModemOrigin           // .fldigi, .wsjtx, .native
}

enum ModemCategory: String, CaseIterable {
    case wsjtWeak = "WSJT Schwachsignal"
    case wsjtBeacon = "WSJT Baken"
    case psk = "PSK-Familie"
    case mfsk = "MFSK-Familie"
    case fsk = "FSK/RTTY"
    case ifk = "IFK-Familie"
    case other = "Sonstige"
    case cw = "CW/Morsen"
}
```

### 3.4 Modem-Registry (Plugin-System)

```swift
/// Zentrale Registry für alle verfügbaren Modems
final class ModemRegistry {
    static let shared = ModemRegistry()

    private var factories: [String: () -> DigitalModem] = [:]

    func register(id: String, factory: @escaping () -> DigitalModem) {
        factories[id] = factory
    }

    func createModem(id: String) -> DigitalModem? {
        factories[id]?()
    }

    var availableModems: [ModemInfo] { ... }

    func modemsByCategory() -> [ModemCategory: [ModemInfo]] { ... }
}

// Registrierung beim App-Start:
ModemRegistry.shared.register(id: "psk31") { PSKModem(variant: .bpsk31) }
ModemRegistry.shared.register(id: "rtty")  { RTTYModem(shift: 170, baud: 45.45) }
ModemRegistry.shared.register(id: "ft4")   { FT4Modem() }
// ... etc.
```

---

## 4. Wiederverwendbare DSP-Bausteine

### 4.1 Was bereits existiert und refactored werden kann

| Bestehend | Kann wiederverwendet werden für |
|-----------|-------------------------------|
| `FT8LDPC.swift` | FT4, JT65 (nach Verallgemeinerung) |
| `FT8CRC.swift` | FT4, alle WSJT-X Modi |
| `FT8CostasSync.swift` | FT4, JT9, JT65 (mit angepassten Costas-Arrays) |
| `FT8MessagePack.swift` | FT4, JT65, JT9, Q65, FST4, MSK144 (gleicher 77-Bit-Rahmen!) |
| `FFTProcessor.swift` | Alle Modi (Spektralanalyse) |
| `AudioEngine.swift` | Alle Modi (Audio I/O) |

### 4.2 Neue Bausteine, die zu erstellen sind

| Baustein | Benötigt für |
|----------|-------------|
| `PSKEngine` (BPSK/QPSK) | PSK31, PSK63, PSK125, PSK250, PSK500, QPSK |
| `VaricodeTable` | PSK31, PSK63 (Zeichencodierung) |
| `BaudotTable` | RTTY (5-Bit-Fernschreibcode) |
| `MFSKEngine` | MFSK, Olivia, Contestia, DominoEX, Thor |
| `GFSKModulator` | FT4, FST4, FST4W |
| `ViterbiDecoder` | Faltungscodes (WSPR, diverse Modi) |
| `ReedSolomonCodec` | JT65 (63,12) Reed-Solomon |
| `WalshHadamard` | JT65 (Symbol-zu-Nachricht) |
| `InterleaverEngine` | Olivia, MT63, diverse |
| `MSKModulator` | MSK144 |
| `HellPixelEngine` | Hellschreiber (Pixel-basiert) |

---

## 5. UI/Bedienkonzept

### 5.1 Zwei Grundtypen von Betriebsarten

Die UI muss zwei fundamental verschiedene Bedienkonzepte unterstützen:

**Typ A: Zeitgetaktete Modi (WSJT-X Stil)**
- FT8, FT4, JT65, JT9, Q65, FST4, MSK144, WSPR, FST4W
- Feste TX/RX-Zyklen, synchron zur Uhr
- Band-Activity-Liste mit decodierten Nachrichten
- Strukturierte QSO-Ablauf (CQ → Antwort → Report → 73)

**Typ B: Keyboard-/Streaming-Modi (Fldigi Stil)**
- PSK31, PSK63, RTTY, Olivia, MT63, MFSK, DominoEX, Thor, FSQ, IFKP
- Freitext, Tastatur-zu-Tastatur Kommunikation
- Laufender Text-Empfang (wie Terminal/Chat)
- Makro-Tasten für Standardphrasen

### 5.2 UI-Konzept: Übersicht

```
┌─────────────────────────────────────────────────────┐
│ DigiFox                          14.074.000  USB    │
│ ┌─────────────────────────────────────────────────┐ │
│ │          Wasserfall / Spektrum                   │ │
│ │  ═══════════════════════════════════════════     │ │
│ │  ▓▓░░░░▓▓▓░░░░░░▓░░░░░░░░░▓▓▓░░░░░░░░░░░     │ │
│ │  ▓▓░░░░▓▓▓░░░░░░▓░░░░░░░░░▓▓▓░░░░░░░░░░░     │ │
│ │  ▓▓░░░░▓▓▓░░░░░░▓░░░░░░░░░▓▓▓░░░░░░░░░░░     │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ ┌─ Mode-Picker ──────────────────────────────────┐ │
│ │ [FT8] [FT4] [JT65] [PSK31] [RTTY] [Olivia] ▸ │ │
│ └─────────────────────────────────────────────────┘ │
│                                                     │
│ ╔═══════════════════════════════════════════════════╗│
│ ║  << Modus-spezifischer Bereich >>                ║│
│ ║                                                   ║│
│ ║  Typ A: Band-Activity + QSO-Panel                ║│
│ ║  ODER                                             ║│
│ ║  Typ B: Text-Terminal + Makro-Leiste              ║│
│ ║                                                   ║│
│ ╚═══════════════════════════════════════════════════╝│
│                                                     │
│ ┌─ TX-Bereich ───────────────────────────────────┐ │
│ │ [Eingabefeld / TX-Steuerung]          [TX] 🔴  │ │
│ └─────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### 5.3 Mode-Picker (Neu)

Der aktuelle Tab-basierte Ansatz (FT8 | JS8 | CW) skaliert nicht auf 25+ Modi. Stattdessen:

```
┌─ Modus wählen ──────────────────────────────────┐
│                                                   │
│  WSJT Schwachsignal                               │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐  │
│  │ FT8  │ │ FT4  │ │ JT65 │ │ JT9  │ │ Q65  │  │
│  │ ●    │ │      │ │      │ │      │ │      │  │
│  └──────┘ └──────┘ └──────┘ └──────┘ └──────┘  │
│                                                   │
│  WSJT Baken                                       │
│  ┌──────┐ ┌──────┐ ┌──────┐                      │
│  │ WSPR │ │FST4  │ │FST4W │                      │
│  └──────┘ └──────┘ └──────┘                      │
│                                                   │
│  PSK-Familie                                      │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐            │
│  │PSK31 │ │PSK63 │ │PSK125│ │QPSK31│            │
│  └──────┘ └──────┘ └──────┘ └──────┘            │
│                                                   │
│  MFSK-Familie                                     │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐            │
│  │Olivia│ │ MT63 │ │MFSK16│ │Contest│            │
│  └──────┘ └──────┘ └──────┘ └──────┘            │
│                                                   │
│  FSK / Klassisch                                  │
│  ┌──────┐ ┌──────┐ ┌──────┐                      │
│  │ RTTY │ │ CW   │ │Hellschr│                    │
│  └──────┘ └──────┘ └──────┘                      │
│                                                   │
│  IFK / Chat                                       │
│  ┌──────┐ ┌──────┐ ┌──────┐ ┌──────┐            │
│  │DomEX │ │ Thor │ │ FSQ  │ │ IFKP │            │
│  └──────┘ └──────┘ └──────┘ └──────┘            │
│                                                   │
│  ★ Favoriten: FT8, PSK31, RTTY (konfigurierbar) │
└───────────────────────────────────────────────────┘
```

### 5.4 Typ-A View: Zeitgetaktete Modi (WSJT-Stil)

Für FT4, JT65, JT9, Q65, FST4, MSK144 — identisches Layout wie FT8:

```
┌─ Band-Aktivität ──────────────────────────────────┐
│  UTC    dB  DT   Freq  Message                     │
│  12:30  -8  0.3  1012  CQ DL1ABC JO31              │
│  12:30 -12  0.1   894  DL1ABC OE3XYZ -14           │
│  12:30  -4  0.2  1523  CQ CONTEST W1AW FN31        │
│  ...                                                │
├─ QSO-Panel ───────────────────────────────────────┤
│  DX Call: [DL1ABC  ]  Grid: [JO31]                 │
│  TX: ○ CQ  ○ Grid  ○ Report  ○ RR73  ○ 73         │
│  [Halt TX]  [Enable TX]  Zyklus: Even ○  Odd ●     │
└────────────────────────────────────────────────────┘
```

### 5.5 Typ-B View: Keyboard-Modi (Fldigi-Stil)

Für PSK31, RTTY, Olivia, MT63, DominoEX, Thor, FSQ, IFKP:

```
┌─ Empfang (RX) ────────────────────────────────────┐
│  CQ CQ CQ de DL1ABC DL1ABC DL1ABC                 │
│  PSE K                                              │
│  ──────────────────────────────                     │
│  DL1ABC de OE3XYZ OE3XYZ                           │
│  GM OM TNX FER CALL UR RST 599 599                 │
│  NAME IS HANS HANS QTH WIEN WIEN                   │
│  HW? AR DL1ABC de OE3XYZ K                         │
│                                           ▼ scroll  │
├─ Senden (TX) ─────────────────────────────────────┤
│  |                                                  │
│  [Tippen Sie hier...]                               │
│                                                     │
├─ Makros ──────────────────────────────────────────┤
│  [CQ] [Antwort] [RST] [Name/QTH] [73] [QSL?]     │
│  [Bake] [Contest Nr] [Eigene...]                    │
└────────────────────────────────────────────────────┘
```

### 5.6 Gemeinsame UI-Elemente

Alle Modi teilen sich:
- **Wasserfall-View** (bereits vorhanden, erweiterbar)
- **Frequenz-Anzeige + VFO** (bereits vorhanden)
- **CAT-Steuerung** (bereits vorhanden)
- **PTT-Steuerung** (bereits vorhanden)
- **Log-Anbindung** (bereits vorhanden)

---

## 6. Implementierungs-Reihenfolge (Phasen)

### Phase 1: Grundlagen & Refactoring (Voraussetzung)
1. `DigitalModem` Protocol definieren
2. `ModemRegistry` implementieren
3. `Codec/Common/DSP/` Verzeichnis mit gemeinsamen Bausteinen anlegen
4. Bestehende FT8/JS8-Codecs auf gemeinsame Bausteine refactoren:
   - `FT8LDPC` → `LDPCCodec` (generisch)
   - `FT8CRC` → `CRCEngine` (generisch)
   - `FT8CostasSync` → `CostasSync` (generisch, parametrierbar)
   - `FT8MessagePack` → `MessagePack77` (für alle WSJT-X Modi)
5. `AudioEngine` erweitern für variable Abtastraten
6. **Mode-Picker UI** als Ersatz für Tab-Navigation

### Phase 2: WSJT-X Modi (naheliegend, da FT8 existiert)
1. **FT4** — Am einfachsten: gleicher Nachrichtenrahmen wie FT8, nur GFSK statt 8-FSK + kürzerer Zyklus
2. **JT9** — Gleicher 77-Bit-Rahmen, 9-FSK statt 8-FSK, 60s-Zyklus
3. **JT65** — Reed-Solomon (63,12) statt LDPC, Walsh-Hadamard-Transform
4. **Q65** — 65-FSK mit variablen Zykluslängen
5. **FST4/FST4W** — GFSK, sehr lange Zyklen (LF/MF)
6. **MSK144** — MSK-Modulation, kurze Bursts (Meteorscatter)

### Phase 3: Fldigi Keyboard-Modi (Kerngruppe)
1. **PSK31/63** — BPSK-Grundmodem + Varicode → Sofort praktisch nutzbar
2. **RTTY** — FSK + Baudot → Zweiter Klassiker
3. **Olivia** — MFSK mit Walsh-Hadamard-FEC → Beliebt für Schwachsignal-Chat

### Phase 4: Fldigi Erweiterte Modi
1. **MT63** — OFDM-artiger Breitband-Modus
2. **MFSK-Familie** (MFSK4 bis MFSK64)
3. **DominoEX / Thor** — IFK+-basierte Modi
4. **Contestia** — Olivia-Variante für Contest
5. **Hellschreiber** — Pixel-basierter Modus (Sonderfall)

### Phase 5: Nischen-Modi
1. **FSQ** — Fast Simple QSO
2. **IFKP** — Weak-signal Chat
3. **Throb/ThrobX** — Experimentell
4. **PSK-R Varianten** — PSK mit Wiederholungscodes
5. **Navtex/SITOR-B** — Maritime Dekodierung
6. **Weather FAX** — Wetterkarten (Bild-Dekodierung)

---

## 7. Technische Schlüsselentscheidungen

### 7.1 Fortran-Code aus WSJT-X
**Problem:** WSJT-X Kernalgorithmen sind in Fortran 90 geschrieben.
**Lösung:** NICHT den Fortran-Code einbinden. Stattdessen:
- Die **mathematischen Algorithmen** in Swift/C reimplementieren
- Die existierende FT8-Implementierung in DigiFox als Referenz nutzen
- Karsten Gobas `ft8_lib` (MIT-Lizenz, reines C) als Referenz für die WSJT-X-Modi
- WSJT-X Fortran-Code nur als **Algorithmus-Referenz** lesen, nicht kompilieren

### 7.2 Fldigi C++-Code
**Problem:** Fldigi nutzt C++ mit starker Kopplung an FLTK-UI.
**Lösung:**
- Die `modem`-Unterklassen (`psk.cxx`, `rtty.cxx`, `olivia.cxx` etc.) als **Algorithmus-Referenz**
- Die DSP-Kerne (Modulation/Demodulation) in Swift reimplementieren
- Fldigi-Quellcode nur zum **Verständnis der Algorithmen** nutzen
- Alternative: Eigenständige C-Bibliotheken für rechenintensive Modi (Olivia FFT, MT63)

### 7.3 Sample-Rate Strategie
| Modus-Gruppe | Samplerate | Begründung |
|-------------|-----------|------------|
| WSJT-X Modi | 12.000 Hz | Kompatibel mit bestehendem FT8 |
| PSK31/63 | 8.000 Hz | Ausreichend, CPU-sparend |
| RTTY | 8.000 Hz | Baudot braucht wenig Bandbreite |
| Olivia/MT63 | 8.000 Hz | Standard für Fldigi-Modi |
| Breitband (MT63-2000) | 12.000 Hz | Für 2 kHz Bandbreite |

### 7.4 Parallele Dekodierung
- AudioEngine liefert Samples an den **aktiven Modem-Decoder**
- Nur ein Decoder läuft gleichzeitig (wie bei Fldigi/WSJT-X)
- Spätere Erweiterung möglich: Multi-Decode (z.B. PSK + CW parallel)

---

## 8. Gemeinsamer Code: Was kann man teilen?

### 8.1 WSJT-X Modi untereinander

```
                    ┌── MessagePack77 ──┐
                    │ (77-Bit Rahmen)   │
                    │ Gemeinsam für:    │
                    │ FT8, FT4, JT65,  │
                    │ JT9, Q65, FST4,  │
                    │ MSK144            │
                    └───────────────────┘
                              │
              ┌───────────────┼────────────────┐
              ▼               ▼                ▼
      ┌──── LDPC ────┐  ┌─ Reed-Sol ─┐  ┌─ Conv. ─┐
      │ FT8, FT4,    │  │ JT65       │  │ WSPR    │
      │ Q65, FST4    │  │            │  │         │
      └──────────────┘  └────────────┘  └─────────┘
              │               │                │
              ▼               ▼                ▼
      ┌── CostasSync ──┐  ┌─ JT65Sync ─┐
      │ FT8, FT4, JT9  │  │ JT65       │
      └────────────────┘  └────────────┘
```

### 8.2 Fldigi Modi untereinander

```
      ┌─── PSKEngine ───┐      ┌── MFSKEngine ──┐
      │ PSK31, PSK63,   │      │ MFSK, Olivia,  │
      │ PSK125, QPSK    │      │ Contestia,     │
      └─────────────────┘      │ DominoEX, Thor │
              │                 └────────────────┘
              ▼                         │
      ┌── Varicode ──┐         ┌── FEC-Engine ──┐
      │ (Zeichencode)│         │ Walsh-Hadamard │
      └──────────────┘         │ Convolutional  │
                               └────────────────┘
```

---

## 9. Risiken und Gegenmaßnahmen

| Risiko | Schwere | Gegenmaßnahme |
|--------|---------|---------------|
| Fortran-Algorithmen schwer nachzuimplementieren | Hoch | ft8_lib (C, MIT) als Referenz; Schrittweise mit einfachen Modi beginnen |
| GPL-Lizenz-Infektion | Hoch | Eigenständige Reimplementierung; nur Algorithmen referenzieren, keinen Code kopieren |
| CPU-Last auf iPhone zu hoch | Mittel | Accelerate-Framework für FFTs; C-Kern für aufwändige Decoder |
| Sample-Rate-Konflikte | Niedrig | AudioEngine mit Resampling erweitern |
| UI wird unübersichtlich bei 25+ Modi | Mittel | Kategorisierter Mode-Picker + Favoriten-System |
| Interoperabilität mit PC-Software | Hoch | Testfälle gegen WSJT-X/Fldigi-Referenz-Implementierungen |

---

## 10. Zusammenfassung

### Was NICHT neu geschrieben wird:
- AudioEngine (erweitert, nicht ersetzt)
- Wasserfall-View (wiederverwendet)
- CAT-Controller / Hamlib (unverändert)
- FT8/JS8/CW/WSPR Decoder (refactored, nicht neu)
- QSO-Logging (erweitert)

### Was NEU geschaffen wird:
- `DigitalModem` Protocol + `ModemRegistry` (Plug-in-System)
- `Codec/Common/DSP/` — gemeinsame DSP-Bausteine
- 15–20 neue Modem-Implementierungen
- Mode-Picker UI
- TextTerminalView (für Keyboard-Modi)
- TimedDecodeView (generisch für alle WSJT-X-Modi)

### Kernprinzipien:
1. **Modular:** Jeder Modus in eigenem Verzeichnis, gemeinsames Interface
2. **Keine GPL-Abhängigkeit:** Algorithmen reimplementieren, nicht kopieren
3. **Gemeinsame Bausteine:** LDPC, CRC, FSK, PSK, MFSK als wiederverwendbare Engines
4. **Zwei UI-Paradigmen:** Zeitgetaktet (WSJT-X) vs. Keyboard (Fldigi)
5. **Schrittweise:** FT4 → JT65 → PSK31 → RTTY → Olivia → Rest
6. **Testbar:** Jeder Codec unabhängig testbar gegen Referenz-Implementierungen
