## Context

DigiFox supports four radio profiles: Digirig, Digirig VOX, (tr)uSDX, and Hermes SDR. The first three require USB serial via IOKit, which is unavailable on stock iOS. Only Hermes SDR (network-based) works. The UI currently shows all four options, confusing users.

## Goals / Non-Goals

**Goals:**
- Hide Digirig, Digirig VOX, and (tr)uSDX from all user-facing UI
- Default to Hermes SDR
- Preserve all backend code for potential future iOS USB serial support

**Non-Goals:**
- Removing or refactoring backend code (CATController, SerialPort, TruSDXSerialAudio, HamlibRig)
- Changing audio pipeline, codec, or Hermes SDR functionality

## Decisions

1. **Filter `RadioProfile` visible cases instead of removing enum cases**
   Add a static `visibleCases` property returning only `[.hermes]`. Backend code continues using all enum cases via `allCases`.

2. **Hide entire USB Devices section in SettingsView**
   The IOKit status, device list, scan, and connect/disconnect buttons are all serial-dependent. Hide the full section.

3. **Hide Rig (CAT) section**
   Hamlib model picker and baud rate are only relevant for serial profiles. Hide when no serial profiles are visible.

4. **Remove radio profile picker when only one option**
   With only Hermes visible, replace the segmented picker with a static label or remove the section header.

5. **Simplify TransceiverStatusBadge**
   Remove the "Digirig" text label and digirig-specific icon logic. Badge should reflect Hermes connection state.

## Risks / Trade-offs

- [Risk] Code drift — deactivated serial code may rot over time → Mitigation: Code remains compilable; RadioProfile enum cases still exist and are used in switches.
- [Risk] Future re-enablement — someone may forget the hidden profiles exist → Mitigation: `visibleCases` is clearly named and documented.
