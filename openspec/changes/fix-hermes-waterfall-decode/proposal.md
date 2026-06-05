## Why

The Hermes Lite 2 SDR connects successfully, but the waterfall shows solid red and FT8 decoding fails. The root cause is a fixed waterfall scale (-60 to 0 dB) that saturates with Hermes signal levels. The HL2's 24-bit ADC at 40 dB LNA gain produces FFT magnitudes well above 0 dB, clipping every bin to maximum color.

## What Changes

- Replace fixed waterfall scaling with adaptive noise floor that handles Hermes signal levels
- Add diagnostic logging to the Hermes audio pipeline (processEP6, feedExternalSamples) for future debugging
- Fix DSPSplitComplex pointer safety warnings in IQProcessor.iqToAudio()

## Capabilities

### New Capabilities

_None._

### Modified Capabilities

_None — bug fix only, no spec-level behavior changes._

## Impact

- **Views**: `WaterfallView.swift` — adaptive scaling
- **Audio**: `IQProcessor.swift` — pointer safety fix
- **Network**: `HermesController.swift` — diagnostic logging
- **No codec changes** — FT8/JS8 demodulators unchanged
