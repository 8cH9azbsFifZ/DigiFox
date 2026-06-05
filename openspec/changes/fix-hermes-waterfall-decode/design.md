## Context

The Hermes Lite 2 produces 24-bit IQ samples at 48 kHz, normalized to [-1, 1]. After USB demodulation (FFT → zero negative frequencies → double positive → IFFT) and decimation to 12 kHz, the audio is fed into AudioEngine's FFT pipeline. The FFTProcessor returns dB values via `vDSP_vdbcon`. The WaterfallView maps these dB values to colors using a fixed range of -60 to 0 dB.

Problem: HL2 at 40 dB LNA gain produces broadband noise that exceeds 0 dB in the FFT output, making every waterfall bin red. An `adaptiveNoiseFloor()` function exists but was disabled because it "hid signals" — likely due to too-narrow dynamic range.

## Goals / Non-Goals

**Goals:**
- Make waterfall display usable with Hermes SDR signal levels
- Preserve waterfall quality for other audio sources (USB audio, TruSDX serial)
- Add logging to diagnose Hermes audio flow issues
- Fix compiler warnings for pointer safety

**Non-Goals:**
- Changing FT8/JS8 demodulator signal processing
- Changing Hermes IQ normalization or gain structure
- Optimizing actor/Task overhead for EP6 processing

## Decisions

1. **Re-enable adaptive noise floor with wider dynamic range**
   The existing `adaptiveNoiseFloor()` calculates 25th percentile as noise floor and 98th percentile as peak. The issue was `max(15, ...)` minimum range was too narrow. Fix: increase minimum to 40 dB and add 10 dB headroom above the peak.

2. **Add Hermes-specific log points**
   Log sample count, RMS, and packet rate in processEP6 (throttled to 1/sec) to enable future diagnosis without live debugging.

3. **Fix DSPSplitComplex with withUnsafeMutableBufferPointer**
   Replace `DSPSplitComplex(realp: &real, imagp: &imag)` with proper pointer-scoped closures to eliminate compiler warnings and potential undefined behavior.

## Risks / Trade-offs

- [Risk] Adaptive scaling might auto-adjust to strong signals, making weak signals less visible → Mitigation: minimum 40 dB range ensures adequate contrast
- [Risk] Logging overhead on hot path → Mitigation: throttle to 1 log/sec
