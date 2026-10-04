## Why

**Status: DEFERRED.** All implementation, entitlement requests and hardware experiments are postponed until the user explicitly resumes this change. The blocker is unavailable serial access on the target Apple device. Complete planning artifacts do not mean permission to implement.

DigiFox should control a conventional transceiver through a Digirig, with QRP Labs QMX support as a potential second target. The current Hermes-only UI hides those use cases, and compiling the existing serial code does not establish that a signed iPhone/iPad app can access USB serial hardware.

Support for both iPhone and iPad is mandatory. An M-series-iPad-only driver is a possible transport experiment, not a complete solution to this requirement. If direct USB cannot support both, an alternative topology requires explicit user approval.

## What Changes

- Establish an explicit Apple-platform feasibility gate for serial CAT, PTT and USB audio before exposing new connection profiles.
- Plan Digirig support with a user-selected transceiver model, baud rate and PTT method; Digirig is an interface, not a rig model.
- Investigate QMX separately: it provides its own USB audio and virtual serial CAT interface and does not require a Digirig.
- Investigate a USBDriverKit extension with an app-facing user client on M-series iPads, including Apple entitlement approval and real-device distribution checks.
- Document the iPhone limitation and alternative BLE or network CAT bridges, without silently changing the single-cable requirement.
- Keep Hermes working and expose serial-dependent profiles only for verified, available transports.

## Capabilities

### New Capabilities

- `serial-radio-control`: Capability-aware Digirig transceiver control, optional QMX control, explicit unsupported-platform states and safe integration of CAT/PTT with USB audio.

### Modified Capabilities

None. No main specifications currently exist under `openspec/specs/`.

## Impact

- `DigiFox/Serial/`: `SerialPort`, `IOKitUSBSerial`, `CP2102USBDriver`, `CATController` and `HamlibRig`.
- `DigiFox/Models/RadioProfile.swift`, `Settings.swift`, `App/AppState.swift` and connection/settings/status views.
- Driver extension, signing and provisioning configuration if the iPad feasibility gate passes; no entitlement approval is assumed.
- Hamlib/C interoperability: the current CAT path expects a serial file path, whereas the USB bridge uses `usb:VID:PID`. A user-client transport requires an explicit adapter or a verified alternative, not a fictitious `/dev` path.
- FT8 and JS8 keep their parallel codec implementations and 12 kHz internal audio rate unchanged; connection, audio routing and TX lifecycle changes must work for both modes.
- This change is a proposal, not an implementation or a promise of direct iPhone USB serial support.
