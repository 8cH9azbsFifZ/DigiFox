## Why

DigiFox ist derzeit auf USB-Serial angewiesen (IOKit, CP2102, Digirig) — das funktioniert nur mit erheblichem Aufwand auf iOS und schließt Netzwerk-SDRs komplett aus. Der **Hermes SDR** (HPSDR/Hermes-Lite2) kommuniziert aber ausschließlich über **UDP/Ethernet** — kein Serial, kein Rooting, kein IOKit nötig. Ein iPad mit USB-C Ethernet-Adapter hat native Netzwerk-Konnektivität. Die gesamte Codec-Schicht (FT8, JS8, WSPR, CW) und das UI sind wiederverwendbar — nur die Hardware-Abstraction muss erweitert werden.

**Warum jetzt:** DigiFox hat bereits das Pattern `feedExternalSamples()` (TruSDX-Pfad), das zeigt, dass externe Audio-Quellen in die Pipeline eingespeist werden können. Ein Hermes-Backend ist die logische Erweiterung.

## What Changes

- **Neues Netzwerk-Transport-Layer**: UDP-basierte Kommunikation mit HPSDR Protocol 1 (Discovery, Start/Stop, I/Q-Streaming, C&C)
- **Neuer RigController für Hermes**: Frequenz, Mode, PTT, LNA-Gain — alles über UDP Command & Control statt Hamlib/Serial
- **Audio-Pipeline-Erweiterung**: I/Q-Samples (48/96/192/384 kHz) vom Hermes empfangen → auf 12 kHz Audio-Band downconvertieren → in bestehende `feedExternalSamples()`-Pipeline einspeisen
- **TX-Pfad**: 12 kHz Modulator-Output → auf Hermes-Samplerate hochrechnen → als I/Q über UDP an Hermes senden + MOX-Bit setzen
- **Device Discovery UI**: Multicast-Discovery (0xEFFE 0x02) statt USB-Device-Scanning
- **Kein Hamlib nötig** für Hermes — CAT-Kontrolle läuft komplett über das HPSDR-Protokoll

**Nicht betroffen:** Alle Codecs (FT8, JS8, WSPR, CW, ARDOP), Waterfall, QSO-Log, UI-Views bleiben unverändert.

## Capabilities

### New Capabilities
- `hermes-discovery`: Netzwerk-Discovery von HPSDR-kompatiblen SDRs via UDP Broadcast
- `hermes-transport`: UDP I/Q Streaming (RX/TX) gemäß HPSDR Protocol 1
- `hermes-rig-control`: Frequenz-, Mode-, PTT-, Gain-Steuerung über HPSDR Command & Control
- `iq-to-audio`: I/Q → Baseband Audio Konvertierung (Downsampling + Frequency Shift)

### Modified Capabilities
<!-- Keine bestehenden Specs vorhanden, daher leer -->

## Impact

- **Code:** Neues Modul `Network/` mit ~4 Swift-Dateien (Discovery, Transport, RigControl, IQConverter)
- **AppState:** Neuer Connection-Typ neben "Digirig" und "TruSDX" → "Hermes SDR"
- **AudioEngine:** `feedExternalSamples()` wird wiederverwendet, evtl. Buffer-Sizing anpassen
- **Dependencies:** Keine neuen externen — Apple `Network.framework` (NWConnection/UDP) reicht
- **Hardware:** iPad + USB-C Ethernet Adapter + Hermes/Hermes-Lite2 im selben Netz
- **FT8/JS8 Codecs:** Null Änderungen — alles downstream von 12 kHz Samples bleibt gleich
- **Hamlib:** Wird für Hermes nicht benötigt — nur für klassische Serial-Rigs weiterhin aktiv
