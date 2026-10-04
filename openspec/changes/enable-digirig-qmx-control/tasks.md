**Status: DEFERRED - blocked by unavailable serial access on the target Apple device.**

All tasks, including feasibility experiments and Apple submissions, are deferred and unchecked. Documentation is complete; implementation is not authorized. Resume only on explicit user instruction. Tasks 2-6 require a successful platform/access gate; QMX additionally requires separate scope approval.

## 1. Platform and access gate (DEFERRED)

- [ ] 1.1 [DEFERRED] Confirm target Apple hardware/OS, transceiver model, Digirig revision, electrical configuration and radio-specific cables.
- [ ] 1.2 [DEFERRED] Capture actual Digirig USB device/interface descriptors on a supported host; record VID/PID and stable device identity rather than assuming the code's defaults.
- [ ] 1.3 [DEFERRED] Submit the technical support questions in design.md to Apple; record the answer separately for iPhone and M-series iPad.
- [ ] 1.4 [DEFERRED] If the M-series iPad route is selected, request the precise DriverKit/USB entitlements and clarify third-party hardware authorization and host-app communication provisioning.
- [ ] 1.5 [DEFERRED] After approval, prove open, bounded read/write and modem-line control in a signed minimal physical-iPad sample; verify distribution provisioning, not just simulator access.
- [ ] 1.6 [DEFERRED] Record a go/no-go decision. If blocked, keep runtime serial features disabled; require a separate user decision before any BLE/network bridge.

## 2. Transport and Hamlib integration (DEFERRED)

- [ ] 2.1 [DEFERRED] Verify supported custom transport hooks in the vendored Hamlib version; prove one end-to-end frequency read without pathname fabrication or competing USB opens.
- [ ] 2.2 [DEFERRED] Decide the production CAT adapter based on 2.1; if Hamlib integration fails, obtain approval for a bounded radio-specific adapter or external bridge.
- [ ] 2.3 [DEFERRED] Define SerialPort's actor-owned transport contract for identity, configuration, ordered I/O, timeout/cancellation, RTS/DTR capabilities and close.
- [ ] 2.4 [DEFERRED] Add the iPad driver extension and app user client with approved entitlements and separate signing profiles. Project regeneration required: first resolve the current generate_project.py/checked-in project setup; use XcodeGen only if an authoritative project.yml is introduced.
- [ ] 2.5 [DEFERRED] Implement CP210x UART configuration and descriptor-based bulk endpoint discovery using supported driver APIs; replace reliance on hard-coded kernel user-client selectors.
- [ ] 2.6 [DEFERRED] Implement exclusive serial ownership shared by CAT and explicit RTS PTT; initialize PTT inactive and disable RTS/CTS flow control.
- [ ] 2.7 [DEFERRED] Wire the adapter from 2.2 into CATController and verify actual model, baud, frequency and mode operations with the selected transceiver.

## 3. Capabilities and user interface (DEFERRED)

- [ ] 3.1 [DEFERRED] Add separate platform, driver, device, serial-handshake and audio capability states with explicit diagnostic failures and German UI messages.
- [ ] 3.2 [DEFERRED] Restore Digirig selection only for verified transports; expose radio model, serial settings, PTT policy and driver activation guidance without enabling unavailable configurations.
- [ ] 3.3 [DEFERRED] Replace the forced-Hermes settings migration with capability-aware behavior while preserving existing Hermes preferences.
- [ ] 3.4 [DEFERRED] Update connection badges and AppState lifecycle handling so only a successful CAT handshake reports the rig connected.

## 4. Audio and safe transmission (DEFERRED)

- [ ] 4.1 [DEFERRED] [FT8+JS8] Verify USB input/output routing independently of CAT and conversion between native hardware rates and the existing 12 kHz codec rate.
- [ ] 4.2 [DEFERRED] [FT8+JS8] Integrate explicit CAT/RTS PTT with TX start, completion, cancellation and timeout; serialize shared serial operations.
- [ ] 4.3 [DEFERRED] [FT8+JS8] Handle device removal, driver loss, audio route changes and app lifecycle transitions: stop queued TX/audio, attempt reachable PTT release, and warn if release is unconfirmed.
- [ ] 4.4 [DEFERRED] Verify driver cleanup/watchdog and physical PTT behavior under failure on a safe bench setup; do not infer hardware release from app state.

## 5. Optional QMX evaluation (DEFERRED)

- [ ] 5.1 [DEFERRED] Obtain explicit QMX scope approval and record firmware, matching CAT manual and actual USB descriptors.
- [ ] 5.2 [DEFERRED] Select and validate QMX's own serial transport independently of CP210x, including required line coding/control behavior.
- [ ] 5.3 [DEFERRED] Verify the installed Hamlib backend or bounded adapter against supported QMX CAT frequency/mode/PTT commands.
- [ ] 5.4 [DEFERRED] [FT8+JS8] Verify QMX USB audio and rate conversion; expose a QMX profile only after serial, audio and safe TX behavior pass the gates.

## 6. Verification and release (DEFERRED)

- [ ] 6.1 [DEFERRED] Add transport tests for partial reads, ordered writes, timeouts, cancellation, duplicate ownership, identity and explicit error reporting.
- [ ] 6.2 [DEFERRED] Add capability/settings tests for unsupported iPhone, disabled iPad driver, audio-only availability and unchanged Hermes behavior.
- [ ] 6.3 [DEFERRED] [FT8+JS8] Run physical-device connect/RX/TX/cancel/unplug checks and record CAT responses plus actual PTT state.
- [ ] 6.4 [DEFERRED] Update user documentation with the verified hardware matrix, wiring prerequisites, driver activation and platform limitations.
- [ ] 6.5 [DEFERRED] Verify extension embedding, signing and export in the release archive, then distribute a separately authorized TestFlight build.
