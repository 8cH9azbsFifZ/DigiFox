# Copilot Instructions for DigiFox

## Build

This is an iOS app (Swift 5.9, iOS 17+) using **XcodeGen** to generate the Xcode project from `project.yml`.

```bash
# Regenerate Xcode project after changing project.yml
xcodegen generate

# Build from command line
xcodebuild -project DigiFox.xcodeproj -scheme DigiFox -sdk iphoneos build
```

There are no tests, linters, or CI pipelines configured.

## Architecture

DigiFox connects to ham radio transceivers via a single USB-C cable to operate FT8 and JS8Call digital modes on iPhone/iPad.

### Core layers

- **AppState** (`App/AppState.swift`) — central `@MainActor ObservableObject` that owns all domain logic: FT8/JS8 RX/TX cycles, rig control, audio engine lifecycle, USB device monitoring, and QSO auto-sequencing.
- **AudioEngine** (`Audio/AudioEngine.swift`) — `AVAudioEngine` wrapper that auto-detects USB Audio Class devices, captures RX audio at 12 kHz via input taps, and plays TX audio via `AVAudioPlayerNode`.
- **CATController** (`Serial/CATController.swift`) — Swift `actor` wrapping `HamlibRig` for rig control (frequency, mode, PTT) over USB serial. Thread-safe by design.
- **SerialPort** (`Serial/SerialPort.swift`) — `actor` wrapping the `IOKitUSBSerial` Objective-C bridge for USB serial device discovery and Digirig detection (VID `0x10C4`).
- **HamlibRig** (`Serial/HamlibRig.swift`) — Swift wrapper around the C Hamlib library (`Frameworks/Hamlib.xcframework`). Supports ~400 rig models; default is FT-817 (model 1020).

### Signal processing pipeline

FT8 and JS8 each have parallel codec implementations under `Codec/FT8/` and `Codec/JS8/`:

```
RX: Audio (12 kHz) → FFT spectrogram → Costas sync → soft symbols → LDPC(174,91) decode → CRC-14 validate → message unpack
TX: Message pack → CRC-14 append → LDPC encode → Gray-coded 8-FSK symbols → Costas sync insert → phase-continuous FSK synthesis
```

Key codec files follow a consistent pattern: `Protocol.swift` (constants), `Modulator.swift`, `Demodulator.swift`, `CostasSync.swift`, `CRC.swift`, `LDPC.swift`, `MessagePack.swift`/`PackMessage.swift`.

### Data flow

Views observe `AppState` via `@EnvironmentObject`. User actions call `AppState` methods (e.g., `transmitFT8()`, `connectRig()`). `AppState` coordinates between `AudioEngine` and `CATController`:

1. RX: Audio buffer fills → demodulator runs every cycle (15s for FT8) → decoded `RxMessage` published to `rxMessages`
2. TX: Message packed → modulated to audio samples → `CATController.pttOn()` → `AudioEngine.transmit()` → PTT off on completion

### Hamlib / C interop

- `Frameworks/Hamlib.xcframework` contains the pre-built static library (device + simulator slices)
- `vendor/hamlib/` has the Hamlib source
- `HamlibStubs/hamlib_missing.c` provides C stubs for symbols missing on iOS (FIFO, timing, snapshot, backend registration)
- `DigiFox-Bridging-Header.h` imports `IOKitUSBSerial.h` for Objective-C serial access; Hamlib is exposed via its xcframework module map

## Conventions

- **SwiftUI + Combine + async/await**: Views use `@EnvironmentObject`, `@Published`, `@AppStorage`. Hardware access uses Swift `actor` isolation.
- **MVVM-ish**: `AppState` acts as both app-wide store and primary view model. `RadioViewModel` exists but `AppState` handles most logic.
- **Module folders**: `Audio/`, `Serial/`, `CAT/`, `Codec/FT8/`, `Codec/JS8/`, `Models/`, `Views/FT8/`, `Views/JS8/`, `Network/`.
- **Codec symmetry**: FT8 and JS8 have mirrored file structures. Changes to one codec often need analogous changes to the other.
- **12 kHz sample rate**: Hardcoded throughout the audio and codec layers. Both FT8 and JS8 are designed around this rate.
- **German UI strings**: User-facing text is in German (e.g., "Rufzeichen", "Einstellungen", "Sende").
- **No package manager**: Dependencies (Hamlib) are vendored as xcframework. No SPM, CocoaPods, or Carthage.
