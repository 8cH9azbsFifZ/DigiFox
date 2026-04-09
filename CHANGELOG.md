# Changelog

All notable changes to DigiFox are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [v0.7.0] - 2026-04-09

### Added
- Digirig VOX profile — audio-only operation without serial connection
- GitHub Actions TestFlight build pipeline for automated distribution
- GPL open source license

## [v0.6.0] - 2026-03-01

### Added
- Integrated `ft8_lib` C library for FT8 LDPC/CRC decoding
- Design document with external source attribution and design principles
- Auto-fill baud rate from Hamlib when rig model is selected
- 3-tier audio routing priority definition (Digirig > TruSDX > built-in)
- USB device discovery debug logging with POSIX `/dev` fallback
- CWToneGenerator added to Xcode project
- Spot reporter documentation in DESIGN.md
- Sample rate conversion principle and Hamlib reference docs

### Fixed
- Fix sample rate: audio buffer always at 12 kHz, `effectiveSampleRate` stays constant
- Fix FT8 decode: correct LDPC(174,91) matrix and Gray code from WSJT-X
- Fix critical FFT bug: use 1920-point DFT for correct FT8 bin spacing
- Fix Digirig baud rate: use user setting instead of hardcoded 9600
- Fix USB audio routing: set preferred input before session activation
- Improve USB audio routing with robust detection, retry, and verbose logging
- Fix TX crash: resample audio to engine output rate
- Fix TX crash: use mixer format directly, guard engine state
- Fix TX crash: stop engine before player setup to prevent disconnect
- Fix TX hang: capture format before engine stop, add safety timeout
- Default to FT-817 (model 1020) when switching back to Digirig profile
- Fix `onChange` deprecation warnings, regenerate project

## [v0.5.0] - 2026-03-01

### Added
- ARDOP codec and Winlink tab with open source references
- Full Winlink stack implementation (Phases 1–3)
- WSPR RX demodulator and full RX/TX cycle
- Editable dial frequency in JS8 and CW views
- Centralized debug logging system with in-app log viewer
- Privacy manifest (`PrivacyInfo.xcprivacy`) for EU App Store distribution
- Digirig reference documentation and protocol docs linked in README

### Fixed
- Fix WSPR frequency display in settings and FT8 callsign in TX messages
- Fix critical Winlink bugs: LZHUF tables (N=2048), MD5 auth (CryptoKit), B2F SOH/STX/EOT framing, ARQ timeouts + DISCACK
- Fix WSPR encoding to match WSJT-X standard
- Translate remaining German comments to English in WinlinkProtocol.swift

### Changed
- Remove obsolete planning and integration documents

## [v0.4.0] - 2026-03-01

### Added
- FT8, JS8, and WSPR transmit (TX) via TruSDX raw audio
- TX Halt button for immediate transmission abort
- Architecture plans for Fldigi & WSJT-X digital modes integration
- Reporting services architecture (WSPRnet, PSK Reporter, RBN, APRS, Winlink)
- Concept document for auto QSO logging, digital logbook & QSL cards
- APRS integration architecture and UI concept

## [v0.3.0] - 2026-03-01

### Added
- CW reception via integrated `ggmorse` CW decoder
- CW waterfall display
- TruSDX serial audio streaming for CW
- CW tab with dedicated icon (`dot.radiowaves.right`)
- `cw-decoder-core` C library integration

## [v0.2.0] - 2026-02-28

### Added
- GPS grid locator for automatic Maidenhead grid square
- Radio profile selection (Digirig / TruSDX)
- Rig frequency and mode polling for live sync
- Bottom tab navigation for FT8 and JS8Call modes
- USB connection badge — green when connected, red when disconnected

### Changed
- Move mode switcher from settings to bottom tabs
- Remove mode picker from settings view (tabs handle mode switching)

### Fixed
- Improve mode picker contrast: inactive segment now clearly visible
- Fix TruSDX device detection and connection

## [v0.1.0] - 2026-02-28

### Added
- Initial project setup with README and AI/experimental disclaimer
- TruSDX integration: CAT control, USB audio, SwiftUI interface
- Self-contained unified FT8 + JS8Call iOS app architecture
- App icon
- TruSDX `CAT_STREAMING` audio protocol implementation and tests
- Hamlib integration via pre-built xcframework

### Fixed
- Fix Xcode project: remove old TruSDX files, add Hamlib headers

---

<!-- KI generiert von Gerolf Ziegenhain -->
