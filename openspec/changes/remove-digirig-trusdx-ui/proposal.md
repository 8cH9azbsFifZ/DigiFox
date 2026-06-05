## Why

USB serial access via IOKit is not available on stock iOS — Digirig and (tr)uSDX connection profiles cannot function on current iOS versions. Showing non-functional options confuses users. The code should be preserved (deactivated) in case Apple enables USB serial in a future iOS release, but the UI must only present the Hermes SDR option.

## What Changes

- Remove Digirig, Digirig VOX, and (tr)uSDX from the radio profile picker (keep enum cases in code)
- Default radio profile to Hermes SDR
- Remove/hide the USB Devices section in SettingsView (IOKit status, device list, scan button, connect/disconnect)
- Remove/hide the Rig (CAT) section (Hamlib model picker, baud rate) since it only applies to serial profiles
- Simplify the `TransceiverStatusBadge` to remove Digirig-specific labels
- Keep all backend code (CATController, SerialPort, TruSDXSerialAudio, RadioProfile enum cases) intact

## Capabilities

### New Capabilities

_None — this is a UI-only reduction._

### Modified Capabilities

_None — no spec-level behavior changes, only UI visibility._

## Impact

- **Views**: `SettingsView.swift`, `ContentView.swift` (TransceiverStatusBadge)
- **Models**: `RadioProfile.swift` (filter `allCases`), `Settings.swift` (default to hermes)
- **No codec/audio/serial code changes** — all backend code stays intact
