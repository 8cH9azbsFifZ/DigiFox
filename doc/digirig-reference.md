# Digirig Mobile — Referenz

Hersteller: [Digirig](https://digirig.net/)
Dokumentation: [Getting Started](https://digirig.net/getting-started/)

## Übersicht

Der [Digirig Mobile](https://digirig.net/product/digirig-mobile/) ist ein kompaktes USB-Audio- und Seriell-Interface für den Betrieb digitaler Betriebsarten (FT8, JS8Call, CW, RTTY etc.) mit klassischen Amateurfunk-Transceivern.

Im Gegensatz zum (tr)uSDX, bei dem Audio und CAT über eine einzige serielle Verbindung laufen, verwendet der Digirig **zwei getrennte Kanäle**:

| Kanal | Funktion | Protokoll |
|-------|----------|-----------|
| USB Audio (UAC) | RX/TX Audio | USB Audio Class 1.0, 12 kHz Mono |
| USB Serial (CDC-ACM) | CAT-Steuerung | Seriell, transceiver-abhängig |

## Hardware

- **USB-Stecker**: USB-C (zum iOS-Gerät)
- **Transceiver-Anschluss**: 3,5 mm TRRS Klinke (Audio + PTT) + je nach Kabel seriell
- **USB VID**: `0x10C4` (Silicon Labs CP2102N)
- **Stromversorgung**: Über USB (kein externes Netzteil nötig)

## Audio-Pfad

```
RX: Transceiver → 3.5mm Klinke → Digirig ADC → USB Audio → iOS AVAudioEngine → Decoder
TX: Encoder → AVAudioEngine → USB Audio → Digirig DAC → 3.5mm Klinke → Transceiver
```

- **Sample Rate**: 12000 Hz (in DigiFox fest konfiguriert)
- **Format**: 16-bit signed PCM, Mono
- **Latenz**: Abhängig von iOS Audio-Buffer-Größe (typisch 256–512 Samples)

## CAT-Steuerung

Die CAT-Steuerung läuft über den eingebauten USB-Seriell-Wandler (CP2102N).
DigiFox nutzt [Hamlib](https://hamlib.github.io/) für die Kommunikation mit dem Transceiver.

### Serielle Parameter (transceiver-abhängig)

| Parameter | Typischer Wert |
|-----------|----------------|
| Baud Rate | 4800 / 9600 / 38400 (je nach Transceiver) |
| Format | 8N1 oder 8N2 |
| Flow Control | None / RTS-CTS |
| PTT | CAT-Kommando oder RTS/DTR |

### Unterstützte Transceiver

Über Hamlib werden ~400 Transceiver-Modelle unterstützt, u.a.:

| Modell | Hamlib ID | Baud Rate |
|--------|-----------|-----------|
| Yaesu FT-817/818 | 1020 | 4800/9600 |
| Yaesu FT-857/897 | 1022/1024 | 4800/9600 |
| Yaesu FT-991A | 1036 | 38400 |
| Icom IC-705 | 3085 | 19200 |
| Icom IC-7300 | 3073 | 19200 |
| Kenwood TS-480 | 2028 | 9600 |
| Elecraft KX2/KX3 | 2048/2046 | 38400 |

Vollständige Liste: [Hamlib Supported Rigs](https://hamlib.github.io/Hamlib/support.html)

### PTT-Steuerung

Je nach Transceiver stehen verschiedene PTT-Methoden zur Verfügung:

1. **CAT PTT** — Über CAT-Kommando (z.B. `TX;` / `RX;` bei Kenwood, `0x08` bei Yaesu)
2. **RTS/DTR** — Hardware-Leitung am seriellen Port
3. **VOX** — Audio-getriggert (kein CAT nötig)

DigiFox nutzt standardmäßig Hamlib CAT PTT.

## DigiFox Implementation

```swift
// RadioProfile.swift
case .digirig:
    // Audio: AVAudioEngine (USB Audio Class device)
    // CAT:   HamlibRig via SerialPort (CP2102N, VID 0x10C4)
    // PTT:   Hamlib CAT command
```

- **Audio**: `AVAudioEngine` erkennt das Digirig automatisch als USB-Audio-Gerät
- **Seriell**: `SerialPort` erkennt das Digirig anhand VID `0x10C4`
- **CAT**: `CATController` → `HamlibRig` → Hamlib C-Library
- **PTT**: Über Hamlib (`rig_set_ptt()`)

## Kabelübersicht

| Transceiver-Typ | Digirig-Kabel |
|------------------|---------------|
| Yaesu FT-8xx | [Digirig Cable for FT-8xx](https://digirig.net/product/digirig-cable-for-yaesu-ft-8xx/) |
| Yaesu FT-991A | [Digirig Cable for FT-991A](https://digirig.net/product/digirig-cable-for-yaesu-ft-991a/) |
| Icom (CI-V) | [Digirig Cable for Icom](https://digirig.net/product/digirig-cable-for-icom/) |
| Kenwood | [Digirig Cable for Kenwood](https://digirig.net/product/digirig-cable-for-kenwood/) |
| Elecraft KX2/KX3 | [Digirig Cable for Elecraft](https://digirig.net/product/digirig-cable-for-elecraft-kx/) |

Aktuelle Kabelliste: [Digirig Store](https://digirig.net/store/)

## Vergleich: Digirig vs. (tr)uSDX

| Eigenschaft | Digirig | (tr)uSDX |
|-------------|---------|----------|
| Audio-Übertragung | USB Audio (UAC) | Seriell (CAT Streaming) |
| CAT-Steuerung | Hamlib (seriell) | TS-480 direkt (seriell) |
| USB-Kanäle | 2 (Audio + Serial) | 1 (Serial only) |
| Sample Rate RX | 12000 Hz, 16-bit | 7825 Hz, 8-bit |
| Sample Rate TX | 12000 Hz, 16-bit | 11520 Hz, 8-bit |
| Transceiver | ~400 Modelle (Hamlib) | Nur (tr)uSDX |
| PTT | Hamlib / RTS / VOX | CAT (`TX0;`/`RX;`) |
| Kabel | USB-C + TRRS | USB-C (nur 1 Kabel) |

## Referenzen

- [Digirig Mobile](https://digirig.net/) — Hersteller-Website
- [Digirig Getting Started](https://digirig.net/getting-started/) — Setup-Anleitung
- [Digirig Store](https://digirig.net/store/) — Kabel und Zubehör
- [Hamlib](https://hamlib.github.io/) — CAT-Control-Bibliothek
- [(tr)uSDX CAT Reference](trusdx-cat-reference.md) — Protokollreferenz für den (tr)uSDX
