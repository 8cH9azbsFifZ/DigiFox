# (tr)uSDX CAT Command Reference

Reference: https://dl2man.de/5-trusdx-details/
Manual: https://dl2man.de/4-trusdx-manual/

## Serial Port Settings

- Baud rate: **115200** (firmware 2.00t+, was 38400 in earlier versions)
- Format: **8N1** (8 data bits, no parity, 1 stop bit)
- Flow control: **None**
- **DTR should be HIGH**
- **RTS should be LOW** on RX, may be **HIGH** to key CW/PTT

## Hardware Connections

- USB and Power Supply can be connected simultaneously. Main PSU has priority over USB 5V.
- External Speaker/Headphone disables on-board speaker.
- External Microphone/Paddle/Key disables on-board mic.

## Supported TS-480 CAT Commands

The (tr)uSDX emulates a Kenwood TS-480 (ID: 020).

Full list: `FA; FAnnnnnn; IF; ID; PS; PS1; AI; AI0; MD; MD0; MD1; MD2; MD3; MD4; MD5; RX; TX; TX0; TX1; TX2; AG0; XT1; RT1; RC; FL0; RS; VX;`

| Command | Description |
|---------|-------------|
| `FA;` | Get frequency (Hz) |
| `FA00014074000;` | Set frequency (Hz, 11 digits) |
| `MD;` | Get mode |
| `MDn;` | Set mode: 1=LSB, 2=USB, 3=CW, 4=FM, 5=AM |
| `IF;` | Get transceiver status (frequency + mode) |
| `ID;` | Get transceiver ID → `020` (TS-480) |
| `TX0;` | Set TX (transmit) state |
| `TX1;` | Set TX state (alt) |
| `TX2;` | Set Tune state (mode must be CW) |
| `RX;` | Set RX (receive) state |
| `PS;` / `PS1;` | Power status |
| `AI;` / `AI0;` | Auto info |
| `AG0;` | AF gain |
| `XT1;` | XIT |
| `RT1;` | RIT ON |
| `RC;` | RIT clear |
| `FL0;` | Filter |
| `RS;` | ? |
| `VX;` | VOX |

**Note**: The `KY text;` command is NOT supported by (tr)uSDX. CW must be keyed
via `TX0;`/`RX;` toggling with proper Morse timing, or via the RTS serial line.

## CW Keying

The (tr)uSDX does NOT support the Kenwood `KY` command for sending CW text.
CW must be keyed manually:

1. Set CW mode: `MD3;`
2. Key down: `TX0;` (or RTS HIGH)
3. Key up: `RX;` (or RTS LOW)
4. Timing is controlled by the host software (PARIS standard)

Built-in CW keyer settings (via menu):
- Speed: 10-40 Paris-WPM (menu 2.5)
- Keyer mode: Iambic-A, Iambic-B, Straight (menu 2.6)
- Keyer swap: ON/OFF (menu 2.7)
- Semi QSK: ON/OFF (menu 2.4)
- Practice mode: ON/OFF (menu 2.8)
- CW Decoder: ON/OFF (menu 2.1)

## CAT Streaming Extensions (Digital Modes without Audio Cables)

Audio is transported over the CAT serial interface — no audio cables or sound cards needed.
Requires firmware 2.00u or newer.

| Command | Description |
|---------|-------------|
| `UA0;` | Streaming OFF (CAT control only) |
| `UA1;` | Streaming ON, speaker ON |
| `UA2;` | Streaming ON, speaker OFF |
| `USnnnnn…;` | Audio data block (unsigned 8-bit bytes until `;`) |

### TX/RX Flow

- In **RX**: TruSDX sends audio stream to host until `TX0;` is issued
- In **TX**: Host sends audio stream to TruSDX until `RX;` is issued

### RX Audio

- TruSDX sends audio blocks as `;US<samples>;`
- **RX sample rate: 7825 Hz**
- Stream continues until `TX0;` is sent by host

### TX Audio

- Host sends audio blocks as `;US<samples>;`
- **TX sample rate: 11520 Hz** (or lower for continuous equidistant sending)
- Stream continues until `RX;` is sent by host

### Audio Format

- 8-bit unsigned PCM (U8)
- Dynamic range: 46 dB
- Byte `0x3B` (`;`) never appears in audio data (firmware increments to `0x3C`)
- Audio stream may be interrupted by CAT at any `;` delimiter
- Audio resumes after CAT with `;US` prefix

## Demuxer State Machine

```
State 0 (cat):        ';' → state 1; else accumulate CAT byte
State 1 (semicolon):  'U' → state 2; else new CAT command, state 0
State 2 (semicolonU): 'S' → state 3 (audio); else "U"+byte as CAT, state 0
State 3 (audio):      ';' → state 1; else decode as audio sample
```

## Menu Reference (via front panel)

| Menu | Setting | Values |
|------|---------|--------|
| 1.1 | Volume | 1-15 (6dB steps), 0=Power-Off |
| 1.2 | Mode | LSB, USB, CW, AM, FM |
| 1.3 | Filter BW | Full, 3000, 2400, 1800, 500, 200, 100, 50 Hz |
| 1.4 | Band | 80, 60, 40, 30, 20, 17, 15, 12, 10m |
| 1.5 | Tuning Steps | 10M, 1M, 0.5M, 100k, 10k, 1k, 0.5k, 100, 10, 1 |
| 1.6 | VFO Mode | VFO-A, B, Split |
| 1.7 | RIT | ON, OFF |
| 1.8 | AGC | ON, OFF |
| 1.9 | NR | 0-8 exponential averaging |
| 1.10 | ATT | 0, -13, -20, -33, -40, -53, -60, -73 dB |
| 1.11 | ATT2 | 0-16 (6dB steps) |
| 1.12 | S-meter | OFF, dBm, S, S-bar |
| 2.1 | CW Decoder | ON, OFF |
| 2.4 | Semi QSK | ON, OFF |
| 2.5 | Keyer speed | 10-40 Paris-WPM |
| 2.6 | Keyer mode | Iambic-A, B, Straight |
| 2.7 | Keyer swap | ON, OFF |
| 2.8 | Practice | ON, OFF |
| 3.1 | VOX | ON, OFF |
| 3.2 | Noise Gate | 0-255 (6dB steps) |
| 3.3 | TX Drive | 0-8 (6dB steps), 8=constant amplitude |
| 3.4 | TX Delay | 0-255 ms |
| 4.1 | CQ Interval | 0-60 s |
| 4.2 | CQ Message | Transmit CQ text |
| 8.1 | PA Bias min | 0-255 (0% RF output) |
| 8.2 | PA Bias max | 0-255 (100% RF output) |
| 8.3 | Ref freq | Si5351 crystal frequency (Hz) |
| 8.4 | IQ Phase | 0-180 degrees |
| 10.1 | Backlight | ON, OFF |

## Compatible Software

- **WSJT-X, JS8Call, WinLink**: Via CAT streaming driver on PC/Linux/RPi
- **FT8CN**: Android FT8 app, supports CAT streaming since v0.91 via USB-OTG
- **PocketRXTX / jAReC**: Dashboard app with CAT streaming support
- **DigiFox**: iOS app with native CAT streaming support

## DigiFox Implementation Notes

- Audio goes entirely over Serial — no USB audio device, no AVAudioEngine
- RX path: Serial → Demuxer → Upsample 7825→12000 Hz → FT8/JS8 decoder
- TX path: FT8/JS8 modulator → Downsample 12000→11520 Hz → `;US<data>;` → Serial
- CW keying: Via `TX0;`/`RX;` toggling with software Morse keyer (MorseKeyer.swift)
- PTT: Via `TX0;`/`RX;` commands (not Hamlib, not AVAudioEngine)
- No Hamlib needed: direct SerialPort access with TruSDXDemuxer for mux/demux
