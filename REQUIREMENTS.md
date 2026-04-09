# DigiFox — Requirements Document

> **Status:** Living document — kept in sync with DESIGN.md and README.md.
> Last updated: 2025-07-18

DigiFox is an iOS app for digital amateur radio modes (FT8, JS8Call, WSPR, CW)
with USB-C connection to transceivers, plus Winlink email capability.

---

## 1. Functional Requirements

### FR-01 — FT8 Encoding and Decoding

DigiFox shall implement WSJT-X-compatible FT8 encoding and decoding per the FT8 protocol specification.

| Parameter          | Value                                              |
|--------------------|----------------------------------------------------|
| Sample rate        | 12,000 Hz                                          |
| Modulation         | 8-FSK, 6.25 Hz tone spacing                       |
| Symbol rate        | 6.25 baud (1,920 samples/symbol)                  |
| Symbols per frame  | 79 (Costas 7 + data 36 + Costas 7 + data 36 + Costas 7) |
| Payload            | 77 bits                                            |
| CRC                | CRC-14, polynomial 0x2757                          |
| FEC                | LDPC(174,91), 83 parity bits                       |
| Cycle time         | 15 seconds                                         |
| Bandwidth          | ~50 Hz                                             |
| Costas array       | `[3, 1, 4, 0, 6, 5, 2]`                           |
| Gray code map      | `[0, 1, 3, 2, 5, 6, 4, 7]`                        |

**RX pipeline:** Audio (12 kHz) → FFT (2048-pt) → Costas sync search → 8-FSK soft symbols → Gray decode → LDPC(174,91) BP decode → CRC-14 validate → message unpack.

**TX pipeline:** Message pack (77 bits) → CRC-14 append (14 bits) → LDPC encode (174 bits) → Gray-coded 8-FSK symbols (79) → Costas sync insert → phase-continuous FSK synthesis.

The LDPC decoder uses the vendored C implementation from ft8_lib (`bp_decode()`). CRC-14 uses ft8_lib's `ftx_compute_crc()`. Parity check matrix and generator matrix originate from WSJT-X.

### FR-02 — JS8Call Messaging

DigiFox shall implement JS8Call encoding and decoding with variable speed modes, free-text messaging, and a codec structure mirroring FT8 (same LDPC(174,91), CRC-14, and Costas sync pipeline).

| Speed Mode | Samples/Symbol | Cycle Time |
|------------|---------------|------------|
| Ultra      | 7,680         | 60 s       |
| Slow       | 3,840         | 30 s       |
| Normal     | 1,920         | 15 s       |
| Fast       | 1,280         | 10 s       |
| Turbo      | 640           | 6 s        |

JS8Call shall support free-text messaging between stations with variable speed selection by the operator.

### FR-03 — CW Keyer and Decoder

DigiFox shall provide CW (Morse code) transmit (keyer) and receive (decoder) capability.

| Parameter        | Value                              |
|------------------|------------------------------------|
| Decoder engine   | ggmorse (C++ library, vendored)    |
| Pitch detection  | 200–1,200 Hz (automatic)          |
| Speed detection  | 5–55 WPM (automatic, Kalman filter)|
| SIMD             | ARM NEON envelope detection        |
| Character set    | ITU-R M.1677 compliant             |

**RX:** Audio (12 kHz) → ggmorse decoder (bandpass → envelope → timing → Morse) → auto pitch/speed detection → text output.

**TX:** Text → Morse timing → rig CW keying via Hamlib or direct serial.

### FR-04 — WSPR Beacon Mode

DigiFox shall implement WSPR (Weak Signal Propagation Reporter) encoding and decoding per the WSJT-X reference.

| Parameter        | Value                                         |
|------------------|-----------------------------------------------|
| Sample rate      | 12,000 Hz                                     |
| Modulation       | 4-FSK, 1.4648 Hz tone spacing                |
| Symbol rate      | 1.4648 baud (8,192 samples/symbol)            |
| Symbols per frame| 162                                           |
| Payload          | 50 bits (callsign + grid + power)             |
| FEC              | Convolutional K=32, rate 1/2                  |
| Polynomials      | poly1=0xF2D05351, poly2=0xE4613C47           |
| Interleaver      | Bit-reversal permutation (256 positions, first 162 used) |
| Sync vector      | 162-bit pseudo-random pattern                 |
| Cycle time       | 120 seconds (even minutes UTC)                |
| Bandwidth        | ~6 Hz                                         |

**RX:** Audio (12 kHz) → FFT → Costas-like sync → 4-FSK demod → convolutional decode (K=32, rate 1/2) → interleaver reverse → message unpack.

**TX:** Message pack (50 bits) → convolutional encode (K=32) → interleave → merge with sync vector → 4-FSK synthesis.

### FR-05 — CAT Control via Hamlib

DigiFox shall provide Computer Aided Transceiver (CAT) control through the Hamlib library supporting approximately 400 rig models.

| Parameter             | Value                                      |
|-----------------------|--------------------------------------------|
| Library               | Hamlib (LGPL-2.1), vendored as xcframework |
| Default rig model     | FT-817 (model 1020)                        |
| Supported operations  | Frequency, mode (USB/LSB/CW/AM/FM/DATA), PTT, CW keying |
| Thread safety         | Swift `actor` isolation (`CATController`)  |
| TruSDX protocol       | Kenwood TS-480 subset (Hamlib model 2028)  |
| Digirig default baud  | 38,400                                     |
| TruSDX baud           | 115,200 (fixed, required for streaming)    |

PTT control uses the RTS line on Digirig. The user-selected rig model determines the default baud rate via `HamlibRig.defaultBaudRate(for:)` querying Hamlib capabilities.

### FR-06 — USB Audio via AVAudioEngine

DigiFox shall capture and play audio through USB Audio Class devices using `AVAudioEngine` at a canonical 12 kHz internal sample rate.

| Parameter              | Value                                      |
|------------------------|--------------------------------------------|
| Internal sample rate   | 12,000 Hz (hardcoded)                      |
| USB native rate        | Typically 48,000 Hz                        |
| Resampling method      | `vDSP_vlint` linear interpolation (Accelerate framework) |
| RX buffer              | 30-second circular buffer                  |
| FFT                    | 2048-point via Accelerate vDSP             |
| USB detection          | `AVAudioSession.currentRoute`, port type `.usbAudio` |

Audio routing priority (highest first):

1. **Digirig** — USB Audio Class (CM108B soundcard), detected via `AVAudioSession`
2. **TruSDX** — Serial audio over CAT (`TruSDXSerialAudio`), detected via IOKit USB scan (VID `0x1A86`)
3. **Built-in mic/speaker** — Fallback for testing or acoustic coupling

### FR-07 — TruSDX Serial Audio Protocol

DigiFox shall support the (tr)uSDX `CAT_STREAMING` protocol for combined CAT control and audio over a single USB serial connection.

| Parameter           | Value                                             |
|---------------------|---------------------------------------------------|
| RX audio streaming  | Enabled via `UA1;` CAT command                    |
| RX framing          | `US<samples>;` blocks over serial                 |
| RX encoding         | 8-bit unsigned PCM, mono                          |
| RX native rate      | 7,812.5 Hz (20 MHz XTAL) or 6,250 Hz (16 MHz)    |
| TX method           | Frequency manipulation via rapid `FA` CAT commands (FSK) |
| Delimiter           | `;` (0x3B) never sent as audio data (incremented to 0x3C) |
| Baud rate           | 115,200 (required for streaming)                  |
| Resampling          | Linear interpolation to/from 12 kHz in `TruSDXSerialAudio` |

### FR-08 — Digirig USB Audio Interface Support

DigiFox shall auto-detect and support the Digirig Mobile USB audio interface for transceiver audio and CAT serial connection.

| Parameter     | Value                                            |
|---------------|--------------------------------------------------|
| Audio chip    | CM108B USB Audio Class soundcard                 |
| Serial chip   | CP2102 USB-to-UART                               |
| VID           | `0x10C4` (Silicon Labs)                          |
| PID           | `0xEA60` (CP2102)                                |
| Detection     | Automatic via IOKit USB scan                     |
| Connection    | USB-C: audio (CM108B) + serial (CP2102) simultaneously |

### FR-09 — Winlink Email

DigiFox shall support Winlink email messaging over three transport modes: Telnet (Internet), P2P (direct station-to-station), and ARDOP (HF radio).

| Component            | Detail                                               |
|----------------------|------------------------------------------------------|
| Protocol             | B2F/FBB message exchange (ported from wl2k-go)       |
| SID                  | `[DigiFox-1.0-B2FHIM$]`                             |
| Authentication       | MD5 challenge/response                               |
| Compression          | LZHUF (N=2048, F=60, threshold=2)                    |
| Framing              | SOH/STX/EOT                                          |
| Telnet servers       | `server.winlink.org:8772`, fallback `cms.winlink.org:8772` |
| Credentials storage  | iOS Keychain                                         |
| Local mailbox        | JSON-based (`WinlinkMailbox`)                        |
| Attachments          | Supported with HF size limits                        |
| Position reports     | GPS position report format (per la5nta/pat)          |
| Gateway lookup       | CMS Gateway API for RMS gateway directory            |

**ARDOP modem parameters:**

| Parameter        | Value                                           |
|------------------|-------------------------------------------------|
| Sample rate      | 12,000 Hz                                       |
| Center frequency | 1,500 Hz                                        |
| Leader tones     | 1,475 / 1,525 Hz                                |
| Bandwidths       | 200 / 500 / 1,000 / 2,000 Hz                   |
| Modulations      | 4FSK, 4PSK, 8PSK, 16QAM                        |
| FEC              | Reed-Solomon GF(256), primitive polynomial 0x11D |
| CRC              | CRC-16 CCITT (polynomial 0x1021, init 0xFFFF)   |
| ARQ              | Automatic Repeat Request with adaptive modulation |

### FR-10 — Spot Reporting

DigiFox shall report decoded FT8, JS8, and WSPR messages to external spotting networks. All reporters are disabled by default and individually toggleable.

| Network                  | Protocol                            | Transport          | Flush Interval |
|--------------------------|-------------------------------------|--------------------|----------------|
| **PSK Reporter**         | IPFIX/UDP binary (RFC 5101), enterprise #30351 | UDP to `pskreporter.info:4739` | 5 min |
| **Reverse Beacon Network** | HTTP POST JSON (Aggregator v6.7)  | HTTPS to `reversebeacon.net` | 10 s |
| **WSPRnet**              | HTTP POST URL-encoded               | HTTPS to `wsprnet.org/post/` | 200 ms delay between POSTs |

Reporters use the station's callsign, grid locator, TX power, and antenna from global settings. No separate login is required. Ported from [wave-owl](https://github.com/gerolfziegenhain/wave-owl).

### FR-11 — QSO Auto-Sequencing

DigiFox shall provide automatic QSO sequencing for FT8 and JS8Call, coordinating RX/TX cycles, message generation, and call/response logic. `AppState` manages the sequencing state machine, including:

- Automatic CQ calling and response handling
- Standard exchange sequences (grid, signal report, RRR/73)
- TX slot timing synchronized to 15-second (FT8) or mode-specific (JS8) boundaries
- Band activity display showing all decoded stations

### FR-12 — Real-Time Waterfall Display

DigiFox shall render a real-time waterfall (spectrogram) display of the received audio spectrum. The waterfall adapts to the active mode's bandwidth and uses a monochrome palette for CW mode. The shared `WaterfallView` component is fed by `FFTProcessor` (Accelerate vDSP).

### FR-13 — GPS Grid Locator

DigiFox shall determine the operator's Maidenhead grid locator from GPS coordinates using `CLLocationManager`. The grid locator is used for:

- FT8/JS8/WSPR message packing (transmitted grid square)
- Spot reporting (station location)
- Winlink position reports

### FR-14 — Debug Logging System

DigiFox shall provide meaningful debug logging via `LogManager` (`os.log` wrapper) with subsystem tags. Required log coverage:

| Category              | Subsystem Tag | Logged Events                                   |
|-----------------------|---------------|------------------------------------------------|
| Connection lifecycle  | `"Serial"`    | Device detected / opened / closed / error      |
| Audio path            | `"Audio"`     | Sample rate negotiation, resampling, buffer sizes |
| CAT control           | `"CAT"`       | Commands sent, responses received, PTT changes |
| Codec cycles          | `"FT8-RX"` etc. | Decode start/end, candidates, decoded messages |
| Network / Winlink     | `"Winlink"`   | Session state transitions, bytes sent/received |

Logs are viewable in-app via `LogOutputView`.

---

## 2. Non-Functional Requirements

### NFR-01 — Platform

DigiFox shall target iOS 17.0+ and iPadOS 17.0+. The app shall run on iPhone and iPad devices equipped with USB-C.

### NFR-02 — Language and Runtime

DigiFox shall be written in Swift 5.9, compiled with Xcode 15+.

### NFR-03 — Fixed 12 kHz Sample Rate

All codec and audio processing shall operate at a fixed 12,000 Hz sample rate. Resampling from hardware-native rates (e.g., 48 kHz USB audio, ~7,825 Hz TruSDX serial) shall occur at the device boundary layer (`AudioEngine` or `TruSDXSerialAudio`), never inside codecs. Codecs are device-agnostic and always receive 12 kHz audio.

### NFR-04 — SwiftUI Interface

The user interface shall be built with SwiftUI, using `@EnvironmentObject` for state propagation, `@AppStorage` for persistent settings, and Combine + async/await for reactive updates. UI strings are in German.

### NFR-05 — No External Package Managers

All dependencies shall be vendored (as xcframework or compiled source). No Swift Package Manager, CocoaPods, or Carthage. The Xcode project is generated via XcodeGen from `project.yml`.

### NFR-06 — License Compatibility

DigiFox shall maintain GPL-3.0-compatible licensing to ensure compatibility with WSJT-X (GPL-3.0) and JS8Call (GPL-3.0) derived code. Vendored libraries:

| Library  | License   | Compatibility |
|----------|-----------|---------------|
| Hamlib   | LGPL-2.1  | ✅ GPL-3.0 compatible |
| ft8_lib  | MIT       | ✅ GPL-3.0 compatible |
| ggmorse  | MIT       | ✅ GPL-3.0 compatible |
| wl2k-go  | MIT       | ✅ GPL-3.0 compatible |

### NFR-07 — Actor Isolation for Hardware

All hardware I/O (serial ports, rig control, ARQ sessions) shall use Swift `actor` isolation for thread safety. Affected actors: `CATController`, `SerialPort`, `ARDOPSession`.

### NFR-08 — External Source Traceability

Every externally sourced algorithm, table, constant, or library shall be documented with origin repo/URL, license, integrated components, and corresponding DigiFox file. This is maintained in DESIGN.md section 5.

---

## 3. Hardware Requirements

### HR-01 — USB-C Connection

DigiFox requires an iOS device with USB-C for connection to external radio hardware. All audio and CAT control signals are carried over USB-C.

### HR-02 — Supported Devices

| Device              | Type                | VID      | PID    | Connection                                    |
|---------------------|---------------------|----------|--------|-----------------------------------------------|
| **Digirig Mobile**  | USB audio + serial  | `0x10C4` | `0xEA60` | CM108B (audio) + CP2102 (serial) over USB-C |
| **(tr)uSDX**        | Serial only         | `0x1A86` | CH340/CH341 | CAT + serial audio over single USB-C cable |
| **Any Hamlib rig**  | Via Digirig         | —        | —      | ~400 supported models via Hamlib library      |

### HR-03 — iOS Private Framework Dependency

USB serial device enumeration requires the IOKit private framework, loaded via `dlopen()` at runtime in the Objective-C bridge (`IOKitUSBSerial.m`).

---

## 4. Constraints

### C-01 — No App Store Distribution

DigiFox uses the IOKit private framework for USB serial enumeration, which prevents App Store approval. Distribution is limited to **TestFlight** (via Ad Hoc / Enterprise provisioning) and direct Xcode installation.

### C-02 — Single USB-C Cable Philosophy

The design philosophy requires that a single USB-C cable carries all signals (audio + CAT control) between the iOS device and the transceiver. This constrains hardware choices to devices that multiplex audio and serial over USB (Digirig, TruSDX).

### C-03 — No CI/CD or Test Infrastructure

No continuous integration pipeline, linter, or automated test suite is currently configured. The unit test target exists but is empty.

### C-04 — AI-Generated Codebase

This project was generated with the assistance of various AI models and is experimental in nature. Use at your own risk.

---

## Traceability Matrix

| Requirement | Key Files                                                      |
|-------------|---------------------------------------------------------------|
| FR-01       | `Codec/FT8/FT8Protocol.swift`, `FT8Modulator.swift`, `FT8Demodulator.swift`, `FT8LDPC.swift`, `FT8CRC.swift`, `FT8CostasSync.swift`, `FT8MessagePack.swift` |
| FR-02       | `Codec/JS8/JS8Protocol.swift`, `JS8Modulator.swift`, `JS8Demodulator.swift`, `JS8LDPC.swift`, `JS8CRC.swift`, `JS8CostasSync.swift`, `PackMessage.swift` |
| FR-03       | `Codec/CW/GGMorseDecoder.swift`, `Codec/CW/CWDecoder.swift`, `Serial/MorseKeyer.swift` |
| FR-04       | `Codec/WSPR/WSPRProtocol.swift`, `WSPRModulator.swift`, `WSPRDemodulator.swift`, `WSPRMessagePack.swift` |
| FR-05       | `Serial/CATController.swift`, `Serial/HamlibRig.swift`, `Frameworks/Hamlib.xcframework` |
| FR-06       | `Audio/AudioEngine.swift`, `Audio/FFTProcessor.swift`         |
| FR-07       | `Audio/TruSDXSerialAudio.swift`                               |
| FR-08       | `Serial/SerialPort.swift`, `Serial/IOKitUSBSerial.h/.m`      |
| FR-09       | `Network/WinlinkProtocol.swift`, `Network/WinlinkTelnet.swift`, `Network/WinlinkP2P.swift`, `Network/ARDOPSession.swift`, `Codec/ARDOP/ARDOP*.swift` |
| FR-10       | `Network/PSKReporter.swift`, `Network/RBNReporter.swift`, `Network/WSPRNetReporter.swift` |
| FR-11       | `App/AppState.swift`                                          |
| FR-12       | `Views/WaterfallView.swift`, `Audio/FFTProcessor.swift`       |
| FR-13       | `Location/LocationManager.swift`                              |
| FR-14       | `App/LogManager.swift`, `Views/LogOutputView.swift`           |
| NFR-01      | `App/DigiFoxApp.swift` (deployment target)                    |
| NFR-05      | `project.yml`, `Frameworks/Hamlib.xcframework`, `vendor/`     |
| NFR-07      | `Serial/CATController.swift`, `Serial/SerialPort.swift`, `Network/ARDOPSession.swift` |

<!-- KI generiert von Gerolf Ziegenhain -->
