## UI Cleanup: Hide Serial-Dependent Radio Profiles

_UI-only change — no new behavioral requirements._

### REMOVED from UI

- Radio profile picker entries: Digirig, Digirig VOX, (tr)uSDX
- USB Devices settings section (IOKit status, device list, scan, connect/disconnect)
- Rig (CAT) settings section (Hamlib model picker, baud rate)
- "Digirig" label in TransceiverStatusBadge

### RETAINED in code

- All `RadioProfile` enum cases (`.digirig`, `.digirigVOX`, `.trusdx`)
- Backend: CATController, SerialPort, TruSDXSerialAudio, HamlibRig
- All AppState logic for serial/trusdx paths

### DEFAULT changed

- `AppSettings.radioProfile` defaults to `.hermes` (was `.digirig`)
