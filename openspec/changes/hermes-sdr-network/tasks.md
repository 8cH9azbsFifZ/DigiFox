# Tasks: hermes-sdr-network

## Phase 1: Transport Layer (Port von wave-owl Python → Swift)

- [ ] **1.1** Create `DigiFox/Network/HermesDiscovery.swift` — Swift actor, UDP broadcast discovery via `NWConnection`. Port logic from `wave-owl/src/hermes_discovery.py` (packet format, response parsing, MAC/board-ID extraction). Use `Network.framework` instead of POSIX sockets.

- [ ] **1.2** Create `DigiFox/Network/HermesProtocol.swift` — Swift actor implementing HPSDR Protocol 1 EP2/EP6 communication. Port from `wave-owl/src/hermes_lite2.py::HermesProtocol`. Includes: connect, start, stop, EP2 register cycle (C0 index rotation), MOX control, frequency setting, LNA gain, TX drive level, EP6 receive + sequence tracking.

- [ ] **1.3** Create `DigiFox/Network/IQProcessor.swift` — Port from `wave-owl/src/hermes_dsp.py::IQProcessor`. EP6 packet parsing: extract 24-bit signed I/Q from USB frames, sign extension, normalize to Float, IQ swap config. Use `Accelerate` for vectorized operations instead of numpy.

- [ ] **1.4** Create `DigiFox/Network/HermesTransport.swift` — High-level actor combining Protocol + IQProcessor. Provides: `onIQReceived: ([Float]) -> Void` callback (already decimated to 12 kHz), `transmit(iq48k:)` for TX. Manages keepalive timer, NWPathMonitor for disconnect detection.

## Phase 2: DSP / Audio Bridge

- [ ] **2.1** Create `DigiFox/Network/IQConverter.swift` — IQ→Audio: extract real part from complex IQ, decimate 48→12 kHz using `vDSP_desamp` or `resampleTo12kHz()` (existing pattern in AudioEngine). Audio→IQ: upsample 12→48 kHz, Hilbert transform via `vDSP_DFT` for analytic signal.

- [ ] **2.2** Extend `AudioEngine.feedExternalSamples()` — Verify buffer sizing works for Hermes data rates (~126 samples/packet at 48 kHz → ~31.5 samples/packet at 12 kHz). May need to adjust `maxBuf` or accumulation strategy.

## Phase 3: Integration in AppState

- [ ] **3.1** Add `ConnectionType.hermes` case — Extend existing connection type enum. Add `hermesTransport: HermesTransport?` property to AppState.

- [ ] **3.2** Implement `connectHermes(ip:)` in AppState — Discovery result → connect → start → wire `onIQReceived` to `audioEngine.feedExternalSamples()`. Mirror TruSDX pattern (lines 250-256 of AppState.swift).

- [ ] **3.3** Implement Hermes TX path in AppState — When `transmitFT8()`/`transmitJS8()` is called and connection is Hermes: modulate → upsample → Hilbert → `hermesTransport.transmit(iq48k:)`. No AVAudioSession needed.

- [ ] **3.4** Implement Hermes frequency/PTT control — When band/frequency changes: call `hermesTransport.setFrequency()`. Replace CATController calls in Hermes mode. PTT via MOX bit (automatic in transport layer).

## Phase 4: UI

- [ ] **4.1** Create `Views/HermesConnectionView.swift` — Device discovery list, manual IP entry, connect/disconnect button, connection status indicator. German UI strings.

- [ ] **4.2** Add Hermes option to connection picker — Extend existing radio connection UI to offer "Hermes SDR (Netzwerk)" alongside Digirig/TruSDX.

- [ ] **4.3** Add LNA gain + TX power controls — Slider UI for Hermes-specific settings (only visible when Hermes connected).

## Phase 5: Polish & Edge Cases

- [ ] **5.1** NWPathMonitor integration — Observe Ethernet adapter connect/disconnect, auto-reconnect logic, UI feedback.

- [ ] **5.2** Background mode handling — Stop Hermes stream when app backgrounds, restart on foreground (iOS app lifecycle).

- [ ] **5.3** Update `generate_project.py` — Add new `Network/` source files to Xcode project generation. Add `Network.framework` to linked frameworks.
