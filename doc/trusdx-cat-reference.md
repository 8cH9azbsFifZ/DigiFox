# (tr)uSDX CAT Command Reference

Reference: https://dl2man.de/5-trusdx-details/

## Serial Port Settings

- Baud rate: **115200** (firmware 2.00t+)
- Format: **8N1** (8 data bits, no parity, 1 stop bit)
- Flow control: **None**
- **DTR should be HIGH**
- **RTS should be LOW** on RX, may be **HIGH** to key CW/PTT

## Supported TS-480 CAT Commands

The (tr)uSDX emulates a Kenwood TS-480 (ID: 020).

| Command | Description |
|---------|-------------|
| `FA;` | Get frequency (Hz) |
| `FA00014074000;` | Set frequency (Hz, 11 digits) |
| `MD;` | Get mode |
| `MDn;` | Set mode: 1=LSB, 2=USB, 3=CW, 4=FM, 5=AM |
| `IF;` | Get transceiver status (frequency + mode) |
| `ID;` | Get transceiver ID → `020` (TS-480) |
| `TX0;` | Set TX (transmit) state |
| `TX2;` | Set Tune state (mode must be CW) |
| `RX;` | Set RX (receive) state |
| `PS;` / `PS1;` | Power status |
| `AI;` / `AI0;` | Auto info |
| `AG0;` | AF gain |
| `KY text;` | Send CW/Morse text |
| `KSnnn;` | Set CW speed (WPM) |

## CAT Streaming Extensions

| Command | Description |
|---------|-------------|
| `UA0;` | Streaming OFF (CAT control only) |
| `UA1;` | Streaming ON, speaker ON |
| `UA2;` | Streaming ON, speaker OFF |
| `USnnnnn…;` | Audio data block (unsigned 8-bit bytes until `;`) |

## Audio Streaming Protocol

### RX (receive)
- TruSDX sends audio blocks as `;US<samples>;`
- **RX sample rate: 7825 Hz**
- Stream continues until `TX0;` is sent by host

### TX (transmit)
- Host sends audio blocks as `US<samples>;`
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

## DigiFox Implementation Notes

- Hamlib model ID: **2028** (Kenwood TS-480 emulation)
- RX audio path: Serial → Demuxer → Upsample 7825→12000 Hz → FT8/JS8 codec
- TX audio path: FT8/JS8 codec → Downsample 12000→11520 Hz → `US<data>;` → Serial
- CW keying: Via `KY text;` command or RTS line HIGH
- PTT: Via `TX0;`/`RX;` commands (not Hamlib PTT for streaming mode)
