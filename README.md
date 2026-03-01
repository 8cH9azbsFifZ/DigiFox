<p align="center">
  <img src="doc/img/logo.png" alt="DigiFox Logo" width="128">
</p>

# DigiFox

iOS app for digital amateur radio modes (**FT8**, **JS8Call**, **CW**) with USB-C connection to transceivers.

## Features

- **FT8** — WSJT-X compatible encoding/decoding, 15-second cycles, auto-sequencing, band activity display, QSO log
- **JS8Call** — Free-text messaging with variable speed (Normal/Fast/Turbo/Slow/Ultra)
- **CW** — Morse code TX (keyer) and RX (decoder) with real-time waterfall display
- **Mode switching** between FT8, JS8Call, and CW via tab bar
- **CAT control** via Hamlib (~400 rig models), Digirig auto-detection
- **USB audio** via AVAudioEngine (12 kHz, 8-FSK) or TruSDX serial audio
- **Waterfall display** in real-time (bandwidth-adapted, monochrome for CW)
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
├── Audio/         AudioEngine, FFTProcessor, TruSDXSerialAudio
├── Codec/
│   ├── FT8/       FT8Protocol, Modulator, Demodulator, LDPC, CRC, CostasSync, MessagePack
│   ├── JS8/       JS8Protocol, Modulator, Demodulator, LDPC, CRC, CostasSync, PackMessage
│   └── CW/        GGMorseDecoder (ggmorse wrapper), MorseKeyer
├── CAT/           CATController (Kenwood TS-480 direct protocol)
├── Serial/        CATController (Hamlib), HamlibRig, SerialPort, IOKitUSBSerial
├── Models/        RadioProfile, Station, Settings
└── Views/         FT8/ + JS8/ + CW/ mode-specific Views, WaterfallView
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

## Acknowledgements

DigiFox builds on the work of several open-source projects:

- **[ggmorse](https://github.com/ggerganov/ggmorse)** by Georgi Gerganov — CW/Morse code decoder with automatic pitch and speed detection (MIT license)
- **[WSJT-X](https://wsjt.sourceforge.io/)** by Joe Taylor (K1JT) et al. — FT8 protocol design and reference implementation (GPL v3). DigiFox contains a clean-room Swift port of the FT8 modulator/demodulator.
- **[JS8Call](http://js8call.com/)** by Jordan Sherer (KN4CRD) — JS8 protocol design and reference implementation (GPL v3). DigiFox contains a clean-room Swift port of the JS8 modulator/demodulator.
- **[Hamlib](https://hamlib.github.io/)** — CAT control library supporting ~400 transceiver models (LGPL)

## License

TBD
