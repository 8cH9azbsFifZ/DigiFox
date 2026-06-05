## 1. RadioProfile: Add visible filter

- [x] 1.1 Add `static var visibleCases: [RadioProfile]` returning only `[.hermes]` to `RadioProfile.swift`

## 2. Settings: Default to Hermes

- [x] 2.1 Change `AppSettings.radioProfileRaw` default from `RadioProfile.digirig.rawValue` to `RadioProfile.hermes.rawValue`
- [x] 2.2 Change `AppSettings.radioProfile` getter fallback from `.digirig` to `.hermes`
- [x] 2.3 Set default `rigModel` to 0 and `rigSerialRate` to 0 (Hermes uses network, not serial)

## 3. SettingsView: Hide serial-only sections

- [x] 3.1 Hide USB Devices section entirely (IOKit status, device list, scan button, connect/disconnect)
- [x] 3.2 Hide Rig (CAT) section (Hamlib model picker, baud rate)
- [x] 3.3 Replace radio profile segmented picker with static "Hermes SDR" label or show only visible profiles
- [x] 3.4 Remove (tr)uSDX baud rate hint from radio profile section
- [x] 3.5 Keep HermesConnectionView visible when Hermes is selected

## 4. ContentView: Simplify TransceiverStatusBadge

- [x] 4.1 Remove `digirigConnected` parameter and "Digirig" text label
- [x] 4.2 Simplify icon/color logic to reflect Hermes-only state

## 5. Build & Deploy

- [x] 5.1 Build and verify no compile errors
- [x] 5.2 Commit changes
- [x] 5.3 Deploy to TestFlight via ios-deploy skill
