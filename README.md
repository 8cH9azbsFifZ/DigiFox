# DigiFox

iOS-App für digitale Amateurfunk-Betriebsarten (**FT8** und **JS8Call**) mit USB-C-Anbindung an Transceiver.

## Features

- **FT8** — WSJT-X-kompatible Kodierung/Dekodierung, 15-Sekunden-Zyklen, Auto-Sequencing, Band-Aktivitätsanzeige, QSO-Log
- **JS8Call** — Freitext-Messaging mit variabler Geschwindigkeit (Normal/Fast/Turbo/Slow/Ultra), Netzwerk-Client-Modus
- **Umschalten** zwischen FT8 und JS8Call per Segmented Control im UI
- **CAT-Steuerung** via Hamlib (~400 Rig-Modelle), Digirig-Erkennung
- **USB-Audio** via AVAudioEngine (12 kHz, 8-FSK)
- **Wasserfall-Anzeige** in Echtzeit
- SwiftUI für iPhone und iPad, iOS 17+

## Architektur

```
DigiFox/
├── App/           DigiFoxApp, AppState (unified), ContentView
├── Audio/         AudioEngine, FFTProcessor
├── Codec/
│   ├── FT8/       FT8Protocol, Modulator, Demodulator, LDPC, CRC, CostasSync, MessagePack
│   └── JS8/       JS8Protocol, Modulator, Demodulator, LDPC, CRC, CostasSync, PackMessage
├── Serial/        CATController, HamlibRig, SerialPort, IOKitUSBSerial
├── Network/       JS8NetworkClient, JS8APIMessage
├── Models/        Message, Settings, Station
└── Views/         Shared + FT8/ + JS8/ mode-specific Views
```

## Setup

1. `python3 generate_project.py`
2. Öffne `DigiFox.xcodeproj` in Xcode
3. Rufzeichen und Grid Locator in den Einstellungen konfigurieren
4. Build & Run auf einem iOS-Gerät

## Voraussetzungen

- iOS 17+ Gerät mit USB-C
- Transceiver mit USB (z.B. Digirig Mobile, (tr)uSDX)
- Xcode 15+

## Disclaimer

Dieses Projekt wurde mit Unterstützung von KI generiert und ist experimentell. Nutzung auf eigene Gefahr.

## Lizenz

TBD
