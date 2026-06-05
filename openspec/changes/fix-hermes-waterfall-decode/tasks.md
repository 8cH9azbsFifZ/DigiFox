## 1. Waterfall: Adaptive scaling

- [ ] 1.1 Re-enable adaptive noise floor in WaterfallView with wider dynamic range (min 40 dB, 10 dB headroom)
- [ ] 1.2 Verify colorMap still produces good contrast across the wider range

## 2. IQProcessor: Pointer safety

- [ ] 2.1 Fix DSPSplitComplex in iqToAudio() using withUnsafeMutableBufferPointer
- [ ] 2.2 Fix DSPSplitComplex in audioToTxIQ() using withUnsafeMutableBufferPointer

## 3. Hermes diagnostics

- [ ] 3.1 Add throttled logging in HermesController.processEP6() — sample count, RMS, packet rate (1/sec)

## 4. Build & Deploy

- [ ] 4.1 Build and verify no compile errors or new warnings in IQProcessor
- [ ] 4.2 Commit and deploy to TestFlight
