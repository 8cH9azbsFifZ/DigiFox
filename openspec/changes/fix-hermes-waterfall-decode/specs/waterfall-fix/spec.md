## Waterfall & Hermes Audio Fix

_Bug fix — no new behavioral requirements._

### FIXED

- Waterfall adaptive scaling re-enabled with minimum 40 dB dynamic range
- DSPSplitComplex pointer lifetime safety in IQProcessor.iqToAudio() and audioToTxIQ()

### ADDED

- Diagnostic logging in HermesController.processEP6() (throttled 1/sec)
