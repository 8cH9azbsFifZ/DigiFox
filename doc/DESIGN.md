# DigiFox — Design Document

> **Status:** Living document — kept up-to-date with every significant change.
> Last updated: 2026-03-01

DigiFox is an iOS app (Swift 5.9, iOS 17+) that connects to ham radio
transceivers via a single USB-C cable to operate FT8, JS8Call, WSPR, and CW
digital modes, plus Winlink email on iPhone/iPad.

---

## Table of Contents

1. [Design Principles](#1-design-principles)
2. [Architecture Overview](#2-architecture-overview)
3. [Module Map](#3-module-map)
4. [Signal Processing Pipeline](#4-signal-processing-pipeline)
5. [External Dependencies & Integrated Sources](#5-external-dependencies--integrated-sources)
6. [Codec Details](#6-codec-details)
7. [Hardware Integration](#7-hardware-integration)
8. [Winlink / ARDOP Networking](#8-winlink--ardop-networking)
9. [Spot Reporters](#9-spot-reporters)
10. [Build System](#10-build-system)
11. [Conventions](#11-conventions)

---

## 1. Design Principles

> ⚠️ **Mandatory reading before making changes.** Every new feature,
> codec, or integration must follow these principles. When in doubt, ask.

### P1 — Audio routing priority for digital modes

All digital modes (FT8, JS8, WSPR, ARDOP, CW) select their audio source
according to the following priority (highest first):

| Priority | Condition | Audio path | Detection |
|----------|-----------|------------|-----------|
| **1** | Digirig connected | USB Audio Class (CM108B soundcard) | `AVAudioSession` port type `.usbAudio` |
| **2** | (tr)uSDX connected (no Digirig) | Serial audio over CAT (`TruSDXSerialAudio`) | IOKit USB scan, VID `0x1A86` |
| **3** | No external device | iPhone built-in microphone / speaker | Fallback |

`AudioEngine` detects USB Audio Class devices via
`AVAudioSession.currentRoute` and routes both input and output to the USB
device automatically. When a TruSDX is connected without a Digirig, audio
is streamed over the serial CAT connection via `TruSDXSerialAudio`. When
no external device is present, the iPhone's built-in audio hardware is
used as fallback so that digital modes remain functional (e.g. for
testing or acoustic coupling).

New codecs or decoders must not bypass this routing — they receive audio
from the shared 12 kHz resampled buffer provided by `AudioEngine`, never
from a self-managed audio source.

### P2 — Prefer integrating original external implementations

When a well-tested, openly licensed reference implementation exists for
a protocol, algorithm, or codec, **integrate it directly** (as vendored C
source, xcframework, or wrapped library) rather than reimplementing it in
Swift from scratch. Reimplementation is acceptable only when:

- The original cannot be compiled for iOS (architecture/API constraints)
- The original has an incompatible license
- Only a small, self-contained algorithm is needed (e.g., a CRC polynomial)

When reimplementing, the ported code **must** reference the exact source
file and version it was ported from (see section 5, "External Dependencies").

### P3 — Fixed 12 kHz sample rate

All codec and audio processing operates at 12,000 Hz. `AudioEngine`
resamples from whatever the USB hardware provides. New codecs must not
introduce a different sample rate.

### P3a — Sample rate conversion at device boundary

Different hardware devices deliver audio at different native sample rates
(see section 7.2). Resampling to the canonical 12 kHz **must** happen at
the device boundary — inside `AudioEngine` (for USB audio) or
`TruSDXSerialAudio` (for serial audio) — before samples reach any codec.
Codecs never resample themselves; they always receive 12 kHz.

When integrating a new audio source or ported codec that assumes a
different sample rate, ensure conversion is handled at the boundary layer,
not inside the codec. This keeps codecs device-agnostic.

| Device | RX native rate | TX native rate | Resampling method |
|--------|---------------|---------------|-------------------|
| **Digirig** (USB audio) | 48,000 Hz | 48,000 Hz | `vDSP_vlint` in `AudioEngine` |
| **(tr)uSDX** (serial audio) | 7,825 Hz | 11,520 Hz | Linear interpolation in `TruSDXSerialAudio` |
| **Built-in mic** (not used for digital modes) | 48,000 Hz | — | N/A (see P1) |

### P4 — Codec symmetry

FT8 and JS8 have mirrored file structures. Changes to shared concepts
(LDPC, CRC, Costas sync) in one codec likely need analogous changes in the
other. New digital modes should follow the same file naming pattern:
`<Mode>Protocol.swift`, `<Mode>Modulator.swift`, `<Mode>Demodulator.swift`, etc.

### P5 — Document every external source

Every externally sourced algorithm, table, constant, or library must be
recorded in section 5 ("External Dependencies & Integrated Sources") of
this document with: origin repo/URL, license, what was integrated, and
which DigiFox file contains it. This enables future updates and license
compliance.

### P6 — Actor isolation for hardware access

All hardware I/O (serial ports, rig control, ARQ sessions) uses Swift
`actor` isolation for thread safety. New hardware integrations must follow
this pattern.

### P7 — Meaningful debug logging

Every significant operation must emit a `Log.d()` message so that runtime
behaviour can be traced after the fact. This includes at minimum:

- **Connection lifecycle:** device detected / opened / closed / error
- **Audio path:** sample rate negotiation, resampling, buffer sizes
- **CAT control:** commands sent, responses received, PTT state changes
- **Codec cycles:** decode start/end, number of candidates, decoded messages
- **Network / Winlink:** session state transitions, bytes sent/received

Use the subsystem tag consistently (e.g. `"Audio"`, `"CAT"`, `"FT8-RX"`,
`"Serial"`, `"Winlink"`). Include key parameters in the message
(model ID, baud rate, sample rate, frequency, etc.) so logs are
self-explanatory without cross-referencing source code.

---

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                        SwiftUI Views                     │
│  FT8View · JS8View · WSPRView · CWView · WinlinkView    │
└────────────────────────┬─────────────────────────────────┘
                         │ @EnvironmentObject
┌────────────────────────▼─────────────────────────────────┐
│                   AppState (@MainActor)                   │
│  Central store & coordinator: RX/TX cycles, QSO logic,   │
│  rig control, audio engine lifecycle, USB monitoring      │
└───┬──────────┬──────────┬──────────┬─────────────────────┘
    │          │          │          │
    ▼          ▼          ▼          ▼
AudioEngine  CATCtrl   Codecs    Winlink
(AVAudio)   (Hamlib)  FT8/JS8   B2F/ARDOP
                      WSPR/CW   Telnet/P2P
```

**Data flow — Receive:**
Audio buffer (12 kHz) → FFT spectrogram → Demodulator (per mode) →
Decoded messages → `AppState.rxMessages` → Views

**Data flow — Transmit:**
User action → `AppState` → Message pack → Modulator → Audio samples →
`CATController.pttOn()` → `AudioEngine.transmit()` → PTT off on completion

---

## 3. Module Map

```
DigiFox/
├── App/
│   ├── AppState.swift          Central @MainActor state & coordinator
│   ├── ContentView.swift       Root tab view
│   ├── DigiFoxApp.swift        App entry point
│   └── LogManager.swift        os.log wrapper
│
├── Audio/
│   ├── AudioEngine.swift       AVAudioEngine: USB audio, FFT, resampling → 12 kHz
│   ├── FFTProcessor.swift      Accelerate vDSP spectrogram
│   └── TruSDXSerialAudio.swift Serial audio streaming from (tr)uSDX radios
│
├── Serial/
│   ├── CATController.swift     Actor: rig control via Hamlib (freq, mode, PTT)
│   ├── HamlibRig.swift         Swift wrapper around C Hamlib library
│   ├── SerialPort.swift        Actor: USB CDC-ACM serial I/O via IOKit
│   ├── MorseKeyer.swift        CW timing and keying
│   ├── IOKitUSBSerial.h/.m     ObjC bridge: private IOKit API for USB enumeration
│   └── (Bridging Header)       Imports IOKitUSBSerial, Hamlib, ft8_lib, ggmorse
│
├── HamlibStubs/
│   └── hamlib_missing.c        C stubs for symbols missing on iOS (FIFO, timing, backends)
│
├── Codec/
│   ├── FT8/                    FT8 codec (7 Swift files + ft8_lib C vendor code)
│   ├── JS8/                    JS8Call codec (7 Swift files, mirrors FT8 structure)
│   ├── WSPR/                   WSPR codec (4 Swift files)
│   ├── ARDOP/                  ARDOP modem (7 Swift files + lzhuf.h)
│   └── CW/                    CW/Morse decoder (2 Swift + 18 C/H/ObjC files)
│
├── Models/
│   ├── BandPlan.swift          HF band definitions and Winlink frequencies
│   ├── Message.swift           RX/TX message model
│   ├── RadioProfile.swift      Rig profile (model, port, baud)
│   ├── Settings.swift          @AppStorage-based settings
│   ├── Station.swift           Station info (callsign, grid, power)
│   ├── WinlinkAccount.swift    Winlink credentials (Keychain-backed)
│   ├── WinlinkAttachment.swift Attachment handling with HF size limits
│   └── WinlinkMessage.swift    Winlink message model & JSON mailbox
│
├── Network/
│   ├── ARDOPSession.swift      ARQ session manager (actor)
│   ├── CMSGatewayAPI.swift     CMS API client for RMS gateway lookup
│   ├── WinlinkP2P.swift        P2P direct station-to-station messaging
│   ├── WinlinkPosition.swift   GPS position reports over Winlink
│   ├── WinlinkProtocol.swift   B2F/FBB message exchange protocol
│   └── WinlinkTelnet.swift     TCP/IP transport to CMS servers
│
├── Location/
│   └── LocationManager.swift   CLLocationManager wrapper
│
└── Views/
    ├── FT8/                    FT8 UI (5 views)
    ├── JS8/                    JS8 UI (4 views)
    ├── WSPR/                   WSPR UI (1 view)
    ├── CW/                     CW UI (3 views)
    ├── Winlink/                Winlink UI (3 views)
    ├── WaterfallView.swift     Shared spectrogram display
    ├── SettingsView.swift      App settings
    └── LogOutputView.swift     Debug log display
```

---

## 4. Signal Processing Pipeline

All codecs operate at a fixed **12 kHz sample rate**. The `AudioEngine`
resamples from whatever the USB hardware provides (typically 48 kHz) down
to 12 kHz using `vDSP_vlint` linear interpolation.

### FT8 (15-second cycle)
```
RX: Audio 12 kHz → FFT (2048-pt) → Costas sync search → 8-FSK soft symbols
    → Gray decode → LDPC(174,91) BP decode → CRC-14 validate → Message unpack

TX: Message pack (77 bits) → CRC-14 (14 bits) → LDPC encode (174 bits)
    → Gray-coded 8-FSK symbols (79) → Costas sync insert → Phase-continuous
    FSK synthesis (1920 samples/symbol, 6.25 Hz spacing)
```

### JS8 (mirrors FT8 structure, variable speed)
Same LDPC/CRC/Costas pipeline as FT8 with different message packing
and multiple speed modes: Normal, Fast, Turbo, Slow, Ultra.

### WSPR (120-second cycle)
```
RX: Audio 12 kHz → FFT → Costas-like sync → 4-FSK demod → Convolutional
    decode (K=32, rate 1/2) → Interleaver reverse → Message unpack

TX: Message pack (50 bits) → Convolutional encode (K=32) → Interleave
    (bit-reversal, 162 of 256) → Merge with sync vector → 4-FSK synthesis
    (8192 samples/symbol, 1.4648 Hz spacing)
```

### ARDOP (variable frame)
```
RX: Audio 12 kHz → Leader detect (1475/1525 Hz) → Frame sync → Multi-carrier
    demod (4FSK/4PSK/8PSK/16QAM) → Reed-Solomon FEC → CRC-16 verify → ARQ

TX: Payload → RS encode → Symbol mapping → Multi-carrier synthesis
    → Leader prepend → Audio output
```

### CW
```
RX: Audio 12 kHz → ggmorse decoder (bandpass → envelope → timing → Morse)
    → Auto pitch (200-1200 Hz) and speed (5-55 WPM) detection → Text output

TX: Text → Morse timing → Rig CW keying via Hamlib (or direct serial)
```

---

## 5. External Dependencies & Integrated Sources

> ⚠️ **This section must be kept current.** Every externally sourced algorithm,
> table, or library used in DigiFox is listed here so future work can trace
> origins, check for updates, and respect licenses.

### 5.1 Vendored Libraries

| Library | Location | Origin | License | Purpose |
|---------|----------|--------|---------|---------|
| **Hamlib** | `Frameworks/Hamlib.xcframework` | [github.com/Hamlib/Hamlib](https://github.com/Hamlib/Hamlib) | LGPL-2.1 | CAT control for ~400 rig models |
| | `vendor/hamlib/` | (headers + static lib) | | |
| **ft8_lib** | `vendor/ft8_lib/`, `Codec/FT8/ft8_lib/` | [github.com/kgoba/ft8_lib](https://github.com/kgoba/ft8_lib) | MIT | FT8 LDPC decoder (`bp_decode`), CRC-14 (`ftx_compute_crc`), Costas/Gray/parity constants |
| **ggmorse** | `vendor/ggmorse/` | [github.com/ggerganov/ggmorse](https://github.com/ggerganov/ggmorse) | MIT | CW/Morse audio decoder |

ft8_lib is compiled as C source and called directly from Swift via the
bridging header (`DigiFox-Bridging-Header.h`). The Swift wrappers
`FT8LDPC.swift` and `FT8CRC.swift` call into the C functions, applying
LLR normalization (variance → 24.0) and sign convention correction before
passing data to `bp_decode()`. This replaced the earlier pure-Swift
reimplementation to improve decode reliability (see commit `9678877`).

### 5.2 Ported / Adapted Algorithms

These are algorithms reimplemented in Swift from external reference
implementations. The original sources are noted so updates can be tracked.

| Algorithm | DigiFox file(s) | Ported from | License | Notes |
|-----------|----------------|-------------|---------|-------|
| **LDPC(174,91) decode** | `Codec/FT8/FT8LDPC.swift` | ft8_lib `ldpc.c` / WSJT-X `bpdecode174.f90` | MIT / GPL-3.0 | Swift wrapper calling C `bp_decode()`; parity check matrix from WSJT-X |
| **LDPC(174,91) encode** | `Codec/FT8/FT8LDPC.swift` | ft8_lib `constants.c` | MIT | Generator matrix (83×12 bytes bitpacked); uses C constants directly |
| **CRC-14 (FT8/JS8)** | `Codec/FT8/FT8CRC.swift`, `Codec/JS8/JS8CRC.swift` | ft8_lib `crc.c` | MIT | FT8: calls C `ftx_compute_crc()`. JS8: Swift reimplementation (same polynomial 0x2757) |
| **LZHUF compression** | `Codec/ARDOP/LZHUFCodec.swift` | wl2k-go [`lzhuf/lzhuf.go`](https://github.com/la5nta/wl2k-go/blob/master/lzhuf/lzhuf.go) | MIT | Original: Okumura/Yoshizaki (1989); N=2048, F=60, threshold=2 |
| **B2F protocol** | `Network/WinlinkProtocol.swift` | wl2k-go [`fbb/b2f.go`](https://github.com/la5nta/wl2k-go/blob/master/fbb/b2f.go) | MIT | SID exchange, challenge/response, SOH/STX/EOT framing |
| **ARDOP modem** | `Codec/ARDOP/ARDOP*.swift` | [pflarue/ardop](https://github.com/pflarue/ardop) | Open source | 4FSK/PSK/QAM multi-carrier, leader tones, frame types |
| **Reed-Solomon GF(256)** | `Codec/ARDOP/ARDOPReedSolomon.swift` | pflarue/ardop | Open source | Primitive polynomial 0x11D (x⁸+x⁴+x³+x²+1) |
| **CRC-16 CCITT** | `Codec/ARDOP/ARDOPCRC.swift` | ARDOP protocol spec | — | Polynomial 0x1021, init 0xFFFF |
| **WSPR convolutional code** | `Codec/WSPR/WSPRProtocol.swift` | WSJT-X | GPL-3.0 | K=32, rate 1/2, poly1=0xF2D05351, poly2=0xE4613C47 |
| **WSPR interleaver** | `Codec/WSPR/WSPRProtocol.swift` | WSJT-X | GPL-3.0 | Bit-reversal permutation (256 positions, first 162 used) |
| **WSPR sync vector** | `Codec/WSPR/WSPRProtocol.swift` | WSPR standard | — | 162-bit pseudo-random pattern |
| **WSPR message packing** | `Codec/WSPR/WSPRMessagePack.swift` | WSJT-X | GPL-3.0 | Callsign/grid encoding with standard character mapping |
| **Winlink Telnet transport** | `Network/WinlinkTelnet.swift` | wl2k-go [`transport/telnet`](https://github.com/la5nta/wl2k-go/tree/master/transport/telnet) | MIT | TCP connection to CMS servers |
| **Winlink P2P mode** | `Network/WinlinkP2P.swift` | [la5nta/pat](https://github.com/la5nta/pat) | MIT | Direct station-to-station messaging |
| **PSK Reporter** | `Network/PSKReporter.swift` | [wave-owl `psk_reporter.py`](https://github.com/gerolfziegenhain/wave-owl/blob/main/src/psk_reporter.py) | MIT | IPFIX/UDP binary protocol (RFC 5101), enterprise #30351 |
| **RBN Reporter** | `Network/RBNReporter.swift` | [wave-owl `rbn_reporter.py`](https://github.com/gerolfziegenhain/wave-owl/blob/main/src/rbn_reporter.py) | MIT | HTTP POST JSON, reverse-engineered from RBN Aggregator v6.7 |
| **WSPRNet Reporter** | `Network/WSPRNetReporter.swift` | [wave-owl `wsprnet_reporter.py`](https://github.com/gerolfziegenhain/wave-owl/blob/main/src/wsprnet_reporter.py) | MIT | HTTP POST URL-encoded, based on WSJT-X reference |
| **Winlink position reports** | `Network/WinlinkPosition.swift` | la5nta/pat | MIT | GPS position report format |
| **CMS Gateway API** | `Network/CMSGatewayAPI.swift` | la5nta/pat | MIT | RMS gateway directory lookup |
| **CW decoder** | `Codec/CW/GGMorseDecoder.swift` + C files | ggmorse | MIT | Bandpass → envelope → Kalman timing → Morse decode |
| **Morse table** | `Codec/CW/morse_table.c` | VE3NEA Morse Expert | — | ITU-R M.1677 compliant character weights |

### 5.3 Critical Constants & Tables (with origin)

| Constant | Value | Source | Used in |
|----------|-------|--------|---------|
| LDPC Nm parity check matrix | 83×7 indices | WSJT-X `ldpc_174_91_c_reordered_parity.f90` | `ft8_lib/constants.h` |
| LDPC generator matrix | 83×12 bytes bitpacked | WSJT-X | `ft8_lib/constants.c` |
| Costas array (FT8/JS8) | `[3,1,4,0,6,5,2]` | FT8 standard | `FT8Protocol.swift`, `JS8Protocol.swift` |
| Gray code map (8-FSK) | `[0,1,3,2,5,6,4,7]` | FT8 standard | `FT8Protocol.swift`, `JS8Protocol.swift` |
| WSPR sync vector | 162-bit pattern | WSPR standard | `WSPRProtocol.swift` |
| WSPR conv. polynomials | 0xF2D05351, 0xE4613C47 | WSJT-X | `WSPRProtocol.swift` |
| RS primitive poly | 0x11D | ARDOP spec | `ARDOPReedSolomon.swift` |
| LZHUF pCode/pLen/dCode/dLen | Position code tables | wl2k-go (verified against C ref) | `LZHUFCodec.swift` |
| CRC-14 polynomial | 0x2757 | ft8_lib | `FT8CRC.swift`, `JS8CRC.swift` |
| CRC-16 polynomial | 0x1021 | ARDOP spec | `ARDOPCRC.swift` |

### 5.4 iOS Private / System Frameworks

| Framework | Usage | Notes |
|-----------|-------|-------|
| **IOKit** (private) | USB CDC-ACM device enumeration | Loaded via `dlopen()` at runtime in `IOKitUSBSerial.m` |
| **AVFoundation** | Audio engine, USB audio routing | Standard public API |
| **Accelerate** | vDSP FFT, resampling (`vDSP_vlint`) | Standard public API |
| **Network** | NWConnection for Winlink Telnet | Standard public API |
| **CoreLocation** | GPS for position reports | Standard public API |
| **Security** | Keychain for Winlink credentials | Standard public API |
| **CryptoKit** | MD5 for Winlink challenge/response | Standard public API |

### 5.5 Bridging Header

`DigiFox-Bridging-Header.h` imports:
```c
#import "IOKitUSBSerial.h"    // ObjC: USB serial device enumeration
#include <hamlib/rig.h>       // C: Hamlib rig control
#include "ggmorse_c_api.h"    // C: ggmorse CW decoder
#include "constants.h"        // C: ft8_lib LDPC/Gray/Costas tables
#include "ldpc.h"             // C: ft8_lib LDPC decoder
#include "crc.h"              // C: ft8_lib CRC-14
```

---

## 6. Codec Details

### 6.1 FT8

| Parameter | Value |
|-----------|-------|
| Sample rate | 12,000 Hz |
| Symbol rate | 6.25 baud (1920 samples/symbol) |
| Modulation | 8-FSK, 6.25 Hz tone spacing |
| Symbols per frame | 79 (7+36+7+36+7: Costas + data) |
| Payload | 77 bits |
| CRC | 14 bits (poly 0x2757) |
| FEC | LDPC(174,91), 83 parity bits |
| Cycle time | 15 seconds |
| Bandwidth | ~50 Hz |

**Files:** `FT8Protocol.swift` (constants), `FT8Modulator.swift`,
`FT8Demodulator.swift`, `FT8CostasSync.swift`, `FT8CRC.swift`,
`FT8LDPC.swift`, `FT8MessagePack.swift`

### 6.2 JS8

Mirrors FT8 codec structure with different message packing and multiple
speed modes. Same LDPC(174,91) and CRC-14.

| Speed | Samples/symbol | Cycle |
|-------|---------------|-------|
| Slow | 3840 | 30s |
| Normal | 1920 | 15s |
| Fast | 1280 | 10s |
| Turbo | 640 | 6s |
| Ultra | 7680 | 60s |

**Files:** `JS8Protocol.swift`, `JS8Modulator.swift`, `JS8Demodulator.swift`,
`JS8CostasSync.swift`, `JS8CRC.swift`, `JS8LDPC.swift`, `PackMessage.swift`

### 6.3 WSPR

| Parameter | Value |
|-----------|-------|
| Sample rate | 12,000 Hz |
| Symbol rate | 1.4648 baud (8192 samples/symbol) |
| Modulation | 4-FSK, 1.4648 Hz tone spacing |
| Symbols per frame | 162 |
| Payload | 50 bits (callsign + grid + power) |
| FEC | Convolutional K=32, rate 1/2 |
| Cycle time | 120 seconds (even minutes UTC) |
| Bandwidth | ~6 Hz |

**Files:** `WSPRProtocol.swift`, `WSPRModulator.swift`,
`WSPRDemodulator.swift`, `WSPRMessagePack.swift`

### 6.4 ARDOP

| Parameter | Value |
|-----------|-------|
| Sample rate | 12,000 Hz |
| Center frequency | 1500 Hz |
| Leader tones | 1475 / 1525 Hz |
| Bandwidths | 200 / 500 / 1000 / 2000 Hz |
| Modulations | 4FSK, 4PSK, 8PSK, 16QAM |
| FEC | Reed-Solomon GF(256) |
| CRC | CRC-16 CCITT (poly 0x1021) |
| ARQ | Automatic Repeat Request with adaptive modulation |

**Files:** `ARDOPProtocol.swift`, `ARDOPModulator.swift`,
`ARDOPDemodulator.swift`, `ARDOPFrameType.swift`, `ARDOPReedSolomon.swift`,
`ARDOPCRC.swift`, `LZHUFCodec.swift`

### 6.5 CW

| Parameter | Value |
|-----------|-------|
| Pitch detection | 200–1200 Hz (auto) |
| Speed detection | 5–55 WPM (auto, Kalman filter) |
| Decoder | ggmorse (C++ library) |
| SIMD | ARM NEON envelope detection |

**Files:** `CWDecoder.swift`, `GGMorseDecoder.swift`, plus 18 C/H/ObjC++ files

---

## 7. Hardware Integration

### 7.1 Supported Devices

| Device | VID | PID | Detection | Connection |
|--------|-----|-----|-----------|------------|
| **Digirig Mobile** | `0x10C4` (Silicon Labs) | `0xEA60` (CP2102) | Auto via IOKit USB scan | USB-C: audio (CM108B) + serial (CP2102) |
| **(tr)uSDX** | `0x1A86` (QinHeng) | CH340/CH341 | Auto via IOKit USB scan | USB-C: serial audio + CAT over single serial |

### 7.2 Audio Path

```
USB Audio Device (48 kHz typically)
  → AVAudioEngine input tap
  → vDSP_vlint resampling → 12 kHz
  → 30-second circular buffer
  → Demodulator consumes per cycle

TX: Modulator generates samples at 12 kHz
  → AVAudioPlayerNode schedules buffer
  → USB Audio output (upsampled by CoreAudio)
```

**TruSDX special case:** Serial audio streaming at ~7825 Hz RX / 11520 Hz TX,
resampled to/from 12 kHz via `TruSDXSerialAudio.swift` (linear interpolation).
See [TruSDX CAT Protocol Reference](trusdx-cat-reference.md) for serial audio
framing details and [Digirig Reference](digirig-reference.md) for USB audio
class details.

**Codec sample rate expectations — all hardcoded to 12 kHz:**

| Codec | Constant | Symbol samples | Notes |
|-------|----------|---------------|-------|
| FT8 | `FT8Protocol.sampleRate` | 1,920 (0.16 s) | |
| JS8 | `JS8Protocol.sampleRate` | 1,920 / 1,280 / 640 / 3,840 / 7,680 (by speed) | 5 speed modes |
| WSPR | `WSPRProtocol.sampleRate` | 8,192 (~0.683 s) | Tone spacing = 12000/8192 ≈ 1.4648 Hz |
| ARDOP | `ARDOPProtocol.sampleRate` | varies by frame type | |
| CW | `GGMorseDecoder.sampleRate` | configurable | Only codec accepting variable rate (default 12 kHz) |

### 7.3 CAT Control

`CATController` (actor) → `HamlibRig` (Swift wrapper) → Hamlib C library

**Hamlib** — the Ham Radio Control Libraries — provides a standardized API for
controlling ~400 amateur radio transceivers. DigiFox uses a pre-built static
library vendored as `Frameworks/Hamlib.xcframework` (device + simulator slices).

- **Reference:** <https://hamlib.github.io/> (source: <https://github.com/Hamlib/Hamlib>)
- **License:** LGPL-2.1
- **iOS stubs:** `HamlibStubs/hamlib_missing.c` provides missing POSIX symbols (FIFO, timing, snapshot, backend registration)

Supports frequency, mode (USB/LSB/CW/AM/FM/DATA), PTT, and CW keying.
Default rig model: FT-817 (model 1020). PTT via RTS line on Digirig.

**Default baud rates** are set per radio profile in `RadioProfile.defaultBaudRate`
and can be overridden by the user in settings. `HamlibRig.defaultBaudRate(for:)`
queries Hamlib capabilities (`serial_rate_max`) for any given model ID.

| Profile | Default baud rate | Source | Notes |
|---------|------------------|--------|-------|
| **Digirig** | 38,400 | `RadioProfile.digirig` | Default for FT-817; user selects rig model, baud auto-updates |
| **(tr)uSDX** | 115,200 | `RadioProfile.trusdx` | Required for `CAT_STREAMING` audio; fixed, not user-configurable |

When the user selects a rig model in Digirig mode, `SettingsView` calls
`HamlibRig.defaultBaudRate(for: modelId)` to auto-set the appropriate rate.

For zero-latency CW keying, `SerialPort.rawFD` exposes the file
descriptor for direct POSIX writes, bypassing the actor isolation.

**Protocol references:**
- [TruSDX CAT Protocol Reference](trusdx-cat-reference.md)
- [Digirig Reference](digirig-reference.md)

---

## 8. Winlink / ARDOP Networking

### 8.1 Protocol Stack

```
┌─────────────────────────────┐
│  WinlinkView (UI)           │
├─────────────────────────────┤
│  B2FSession                 │  B2F/FBB message exchange protocol
│  (WinlinkProtocol.swift)    │  (ported from wl2k-go/fbb)
├──────────┬──────────────────┤
│ Telnet   │ ARDOP Transport  │  Transport layer
│ (TCP/IP) │ (ARQ over HF)    │
├──────────┴──────────────────┤
│  LZHUF Compression          │  (ported from wl2k-go/lzhuf)
├─────────────────────────────┤
│  WinlinkMailbox (JSON)      │  Local message storage
│  WinlinkAccount (Keychain)  │  Credentials
└─────────────────────────────┘
```

### 8.2 Connection Modes

- **Telnet (Internet):** TCP to `server.winlink.org:8772`, fallback `cms.winlink.org:8772`
- **ARDOP (HF):** ARQ session to RMS gateway via ARDOP modem
- **P2P (Direct):** Station-to-station without gateway, ARDOP ARQ + B2F

### 8.3 B2F Protocol Flow

1. SID exchange (`[DigiFox-1.0-B2FHIM$]`)
2. Challenge/response login (MD5)
3. Outbound proposals + compressed data (SOH/STX/EOT framing)
4. Inbound proposals + compressed data
5. FF/FQ termination

---

## 9. Spot Reporters

Decoded messages (FT8, JS8, WSPR) are automatically reported to external
spotting networks when enabled. All reporters are disabled by default and
can be toggled individually in Settings. They use the station's callsign
and grid locator from the global settings — no separate login required.

Ported from [wave-owl](https://github.com/gerolfziegenhain/wave-owl)
(Python → Swift). See section 5.2 for origin references.

### 9.1 Supported Networks

| Network | Protocol | File | Flush interval |
|---------|----------|------|---------------|
| **PSK Reporter** | IPFIX/UDP binary (RFC 5101) | `Network/PSKReporter.swift` | 5 min |
| **Reverse Beacon Network** | HTTP POST JSON (Aggregator v6.7) | `Network/RBNReporter.swift` | 10 s |
| **WSPRnet** | HTTP POST URL-encoded | `Network/WSPRNetReporter.swift` | 200 ms delay between POSTs |

### 9.2 Data Flow

```
Demodulator → RxMessage → AppState.reportSpot()
                              ├── PSKReporter.report(spot)   → UDP to pskreporter.info:4739
                              ├── RBNReporter.report(spot)   → HTTP to reversebeacon.net
                              └── WSPRNetReporter.reportWSPR() → HTTP to wsprnet.org/post/
```

### 9.3 Settings

| Setting | Key | Default | Scope |
|---------|-----|---------|-------|
| PSK Reporter enabled | `pskReporterEnabled` | `false` | Per-reporter toggle |
| RBN enabled | `rbnReporterEnabled` | `false` | Per-reporter toggle |
| WSPRnet enabled | `wsprNetReporterEnabled` | `false` | Per-reporter toggle |
| TX Power (W) | `txPowerWatts` | `5` | Global station info |
| Antenna | `antenna` | `""` | Global station info (sent to PSK Reporter) |

---

## 10. Build System

**XcodeGen** generates the Xcode project from `project.yml`.

```bash
xcodegen generate                    # Regenerate .xcodeproj
xcodebuild -project DigiFox.xcodeproj -scheme DigiFox -sdk iphoneos build
```

- **No package manager** — all dependencies vendored
- **No CI/CD** pipeline
- **No tests** configured (unit test target exists but is empty)
- **No linter** configured

---

## 11. Conventions

- **Language:** Swift 5.9, iOS 17+
- **UI:** SwiftUI + Combine + async/await
- **Comments & documentation:** English
- **UI strings:** German (e.g., "Rufzeichen", "Einstellungen", "Sende")
- **Architecture:** MVVM-ish — `AppState` as central store and primary view model
- **Concurrency:** Hardware access via Swift `actor` isolation (`CATController`, `SerialPort`, `ARDOPSession`)
- **Sample rate:** 12 kHz hardcoded throughout audio and codec layers
- **Codec symmetry:** FT8 and JS8 have mirrored file structures
- **Dependencies:** Vendored as xcframework or source; no SPM/CocoaPods/Carthage
