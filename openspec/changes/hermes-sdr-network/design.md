## Context

DigiFox kommuniziert aktuell nur über USB-Serial (IOKit/CP2102) mit Transceivern. Das schränkt die Hardware auf Rigs mit serieller CAT-Steuerung + Digirig/TruSDX ein. Netzwerk-SDRs wie der Hermes/Hermes-Lite2 nutzen das HPSDR Protocol 1 — ein UDP-basiertes Protokoll für Discovery, I/Q-Streaming und Rig-Kontrolle.

**Bestehendes Pattern:** Der TruSDX-Pfad zeigt bereits, wie externe Audio-Quellen (`feedExternalSamples()`) in die 12-kHz-Pipeline eingespeist werden. Der Hermes-Pfad folgt demselben Muster, liefert aber I/Q statt Audio.

**Plattform-Vorteil:** iOS unterstützt USB-C Ethernet-Adapter nativ. `Network.framework` (NWConnection) erlaubt UDP ohne Jailbreak/Entitlements.

**Referenz-Implementierung:** Das `wave-owl` Projekt (Python, gleiches Repo-Ökosystem) hat eine vollständige, getestete HPSDR Protocol 1 Implementierung:
- `src/hermes_discovery.py` — UDP Broadcast Discovery mit MAC/Board-ID Parsing
- `src/hermes_dsp.py` — IQProcessor (EP6 Parsing, 24-bit IQ → complex64, IQ swap)
- `src/hermes_lite2.py` — HermesProtocol (connect/start/stop, EP2 Keepalive, C&C Register Cycle, TX Audio, Telemetry)
- `src/hermes_adapter.py` — BaseReceiver Adapter (IQ → Audio Konvertierung)
- `src/hermes_tx.py` — MOX-basierter TX Backend
- `docs/protocols/hpsdr-protocol1.md` — Protokoll-Dokumentation

Diese Python-Implementierung dient als 1:1 Vorlage für die Swift-Portierung.

## Goals / Non-Goals

**Goals:**
- iPad kann Hermes/Hermes-Lite2 über Ethernet betreiben (FT8, JS8, WSPR, CW)
- Kein Jailbreak, kein IOKit, keine privaten APIs
- Bestehende Codec-Pipeline (12 kHz) unverändert wiederverwendbar
- Gleichzeitig zum bestehenden Serial-Pfad — User wählt Connection-Typ

**Non-Goals:**
- Protocol 2 (neues openHPSDR-Protokoll) — nur Protocol 1
- Wideband-Spektrum-Display (Hermes kann 0-38 MHz, aber nicht in v1)
- Mehrere RX-Kanäle gleichzeitig (nur 1 RX-Slice für Digital-Mode)
- Ersatz des bestehenden Serial-Pfads — der bleibt parallel bestehen
- Full SDR UI (Panadapter, S-Meter etc.) — nur was für Digital Modes nötig ist

## Decisions

### 1. Transport: `Network.framework` (NWConnection UDP)

**Warum:** Native Apple API, kein Jailbreak, unterstützt Multicast/Broadcast, kein Socket-Boilerplate. Alternative wäre POSIX Sockets — mehr Code, gleiche Funktionalität.

### 2. Architektur: Swift Actor `HermesTransport`

```
┌─────────────────────────────────────────────────────┐
│                    AppState                           │
├─────────────────────────────────────────────────────┤
│  connectionType: .serial | .trusdx | .hermes         │
└─────────┬──────────────────┬───────────────┬────────┘
          │                  │               │
   CATController      TruSDXSerial    HermesController
   (actor, Hamlib)    (serial audio)     (actor, UDP)
                                              │
                                    ┌─────────┴─────────┐
                                    │  HermesTransport   │
                                    │  (actor)           │
                                    ├───────────────────┤
                                    │ • discovery()     │
                                    │ • start(rx:)      │
                                    │ • stop()          │
                                    │ • setFreq()       │
                                    │ • setMOX()        │
                                    │ • onIQReceived    │
                                    └───────────────────┘
                                              │ UDP
                                    ┌─────────┴─────────┐
                                    │  Hermes SDR HW    │
                                    │  (Ethernet)       │
                                    └───────────────────┘
```

**Warum Actor:** Thread-Safety bei UDP-Callbacks (können von beliebigen Queues kommen). Passt zum bestehenden Pattern (CATController, SerialPort sind actors).

### 3. I/Q → Audio Konvertierung

Der Hermes liefert I/Q-Samples (komplex, zentriert auf 0 Hz nach NCO-Mix). Für FT8/JS8 brauchen wir reales Audio (0-3 kHz Baseband).

**Ansatz:** 
```
Hermes RX I/Q (48 kHz) → magnitude = sqrt(I² + Q²)  [oder Re-Teil bei USB-Demod]
                        → Dezimierung auf 12 kHz (Accelerate/vDSP)
                        → feedExternalSamples()
```

Genauer: Da der NCO des Hermes auf die Dial-Frequenz gesetzt wird und FT8 bei +1000-3000 Hz liegt, empfangen wir das Band bereits basebanded. Einfache USB-Demodulation (nur Real-Teil) oder Magnitude reicht für das 0-3 kHz Fenster.

**Alternative:** Full DSP mit Hilbert-Filter — unnötig komplex für den Use Case.

### 4. TX-Pfad

```
FT8Modulator → 12 kHz real samples
            → Hilbert-Transform → analytisches Signal (I/Q)
            → Upsample auf 48 kHz (Accelerate)
            → In HPSDR TX-Frames packen + MOX-Bit setzen
            → UDP an Hermes senden
```

**Warum Hilbert:** Hermes erwartet I/Q für TX. Aus den realen 12-kHz-Samples muss ein analytisches Signal erzeugt werden. Accelerate bietet `vDSP_DFT` dafür.

### 5. Discovery: UDP Broadcast

```swift
// Sende 0xEFFE 0x02 + 60 Bytes Nullen an Port 1024 (Broadcast)
// Hermes antwortet mit MAC, IP, Board-ID, Firmware-Version
```

Zeige gefundene Geräte in einer Liste (ähnlich USB-Device-Picker).

### 6. Frequenz-Steuerung: HPSDR Command & Control

Statt Hamlib CAT-Befehlen setzt man direkt C&C-Register:
- `ADDR 0x01`: TX NCO Frequency (32-bit Hz)
- `ADDR 0x02`: RX1 NCO Frequency (32-bit Hz)  
- `ADDR 0x09[31:28]`: TX Drive Level
- `C0[0]`: MOX bit für PTT

Kein Hamlib involviert — deutlich simpler.

## Risks / Trade-offs

| Risk | Mitigation |
|------|-----------|
| iPad-Ethernet-Adapter nicht immer erkannt | `NWPathMonitor` beobachten, UI-Feedback bei Disconnect |
| Hermes Watchdog killt Verbindung bei Stall | Regelmäßige C&C-Frames senden (mind. alle 200ms) |
| Latenz UDP vs. Serial-Audio | Kein Problem: FT8 hat 15s Zyklen, Jitter von <50ms irrelevant |
| I/Q→Audio Qualität | Für WSJT-X-artige Dekodierung reicht simple Demod — keine HiFi-Anforderung |
| Broadcast-Discovery funktioniert nicht über Subnets | Fallback: manuelle IP-Eingabe |
| AVAudioSession-Konflikt wenn kein USB-Audio | Hermes braucht kein AVAudioSession — komplett netzwerkbasiert |
| Battery Drain durch permanentes UDP | `NWConnection` ist energieeffizient; Hermes-Frames sind klein (1032 Bytes) |

## Open Questions

1. **Samplerate-Wahl:** 48 kHz reicht für FT8/JS8 (Bandbreite <4 kHz). Höhere Raten (96/192/384) wären Verschwendung — oder nützlich für Wideband-Wasserfall in v2?
2. **Duplex:** Hermes kann simultan RX+TX. Nutzen wir das für Full-Duplex Monitoring?
3. **LNA Gain UI:** Soll der User den Hermes-LNA steuern können, oder Auto-AGC?
4. **Multi-Hermes:** Kann man mehrere Hermes im Netz haben und einen auswählen?
