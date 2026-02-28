<p align="center">
  <img src="doc/img/logo.png" alt="DigiFox Logo" width="128">
</p>

# DigiFox

iOS app for digital amateur radio modes (**FT8** and **JS8Call**) with USB-C connection to transceivers.

## Features

- **FT8** — WSJT-X compatible encoding/decoding, 15-second cycles, auto-sequencing, band activity display, QSO log
- **JS8Call** — Free-text messaging with variable speed (Normal/Fast/Turbo/Slow/Ultra), network client mode
- **Mode switching** between FT8 and JS8Call via segmented control in the UI
- **CAT control** via Hamlib (~400 rig models), Digirig auto-detection
- **USB audio** via AVAudioEngine (12 kHz, 8-FSK)
- **Waterfall display** in real-time
- SwiftUI for iPhone and iPad, iOS 17+

## Supported Hardware

### (tr)uSDX

The [(tr)uSDX](https://dl2man.de/) is a compact QRP transceiver. DigiFox supports its `CAT_STREAMING` protocol — **both CAT control and audio over a single USB-C cable**:

- **CAT control** — Kenwood TS-480 protocol subset (Hamlib model 2028)
- **RX audio streaming** — Enabled via `UA1;` CAT command:
  - Audio sent as `US<samples>;` blocks over the serial connection
  - 8-bit unsigned PCM, mono, 7812.5 Hz sample rate (20 MHz XTAL) or 6250 Hz (16 MHz)
  - The `;` byte (0x3B) is never sent as audio data (incremented to 0x3C), used only as CAT delimiter
  - Baud rate: **115200** (required for streaming)
- **TX for digital modes** — Frequency manipulation via rapid `FA` CAT commands (FSK)

### Digirig

Standard USB audio interface + separate CAT serial connection to any Hamlib-supported transceiver.

## Architecture

```
DigiFox/
├── App/           DigiFoxApp, AppState (unified), ContentView
├── Audio/         AudioEngine, FFTProcessor, USBAudioManager, TruSDXSerialAudio
├── Codec/
│   ├── FT8/       FT8Protocol, Modulator, Demodulator, LDPC, CRC, CostasSync, MessagePack
│   └── JS8/       JS8Protocol, Modulator, Demodulator, LDPC, CRC, CostasSync, PackMessage
├── CAT/           CATController (Kenwood TS-480 direct protocol)
├── Serial/        CATController (Hamlib), HamlibRig, SerialPort, USBSerialPort, IOKitUSBSerial
├── Models/        RadioProfile, Station, Settings
├── ViewModels/    RadioViewModel
├── Network/       JS8NetworkClient, JS8APIMessage
└── Views/         Shared + FT8/ + JS8/ mode-specific Views, WaterfallView
```

## Setup

1. Open `DigiFox.xcodeproj` in Xcode
2. Configure callsign and grid locator in settings
3. Build & Run on an iOS device

## Requirements

- iOS 17+ device with USB-C
- Transceiver with USB (e.g. Digirig Mobile, (tr)uSDX)
- Xcode 15+

## Disclaimer

This project was generated with the assistance of various AI models and is experimental in nature. Use at your own risk.

## License

TBD
