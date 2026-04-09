# References

All externally sourced algorithms, libraries, protocols, and standards used in DigiFox.

## Libraries (Vendored)

| Library | Location | Source | License | Purpose |
|---------|----------|--------|---------|---------|
| **Hamlib** | `Frameworks/Hamlib.xcframework`, `vendor/hamlib/` | [hamlib.github.io](https://hamlib.github.io/) | LGPL-2.1 | CAT rig control (~400 models) |
| **ft8_lib** | `Codec/FT8/ft8_lib/` | [github.com/kgoba/ft8_lib](https://github.com/kgoba/ft8_lib) | MIT | FT8 LDPC decoder, CRC-14, constants |
| **ggmorse** | `Codec/CW/` (C files) | [github.com/ggerganov/ggmorse](https://github.com/ggerganov/ggmorse) | MIT | CW/Morse audio decoder |

## Ported / Reimplemented Algorithms

| Algorithm | File | Original Source | License | Notes |
|-----------|------|----------------|---------|-------|
| LDPC(174,91) decode | `Codec/FT8/FT8LDPC.swift` | ft8_lib `ldpc.c` / WSJT-X `bpdecode174.f90` | MIT / GPL-3.0 | Swift wrapper calling C `bp_decode()` |
| LDPC(174,91) encode | `Codec/FT8/FT8LDPC.swift` | ft8_lib `constants.c` | MIT | Generator matrix (83×12 bytes bitpacked) |
| CRC-14 (FT8/JS8) | `Codec/FT8/FT8CRC.swift`, `Codec/JS8/JS8CRC.swift` | ft8_lib `crc.c` | MIT | Polynomial 0x2757 |
| LZHUF compression | `Codec/ARDOP/LZHUFCodec.swift` | wl2k-go [`lzhuf/lzhuf.go`](https://github.com/la5nta/wl2k-go/blob/master/lzhuf/lzhuf.go) | MIT | Okumura/Yoshizaki (1989); N=2048, F=60 |
| B2F protocol | `Network/WinlinkProtocol.swift` | wl2k-go [`fbb/b2f.go`](https://github.com/la5nta/wl2k-go/blob/master/fbb/b2f.go) | MIT | SID exchange, SOH/STX/EOT framing |
| ARDOP modem | `Codec/ARDOP/ARDOP*.swift` | [pflarue/ardop](https://github.com/pflarue/ardop) | Open source | 4FSK/PSK/QAM multi-carrier |
| Reed-Solomon GF(256) | `Codec/ARDOP/ARDOPReedSolomon.swift` | pflarue/ardop | Open source | Primitive polynomial 0x11D |
| CRC-16 CCITT | `Codec/ARDOP/ARDOPCRC.swift` | ARDOP protocol spec | — | Polynomial 0x1021, init 0xFFFF |
| WSPR convolutional code | `Codec/WSPR/WSPRProtocol.swift` | WSJT-X | GPL-3.0 | K=32, rate 1/2, poly 0xF2D05351 / 0xE4613C47 |
| WSPR interleaver | `Codec/WSPR/WSPRProtocol.swift` | WSJT-X | GPL-3.0 | Bit-reversal permutation (162 of 256) |
| WSPR message packing | `Codec/WSPR/WSPRMessagePack.swift` | WSJT-X | GPL-3.0 | Standard callsign/grid encoding |

## Network Protocol References

| Protocol | File | Reference Implementation | License | Notes |
|----------|------|-------------------------|---------|-------|
| PSK Reporter (IPFIX/UDP) | `Network/PSKReporter.swift` | [wave-owl `psk_reporter.py`](https://github.com/gerolfziegenhain/wave-owl/blob/main/src/psk_reporter.py) | MIT | RFC 5101, enterprise #30351 |
| RBN Reporter (HTTP/JSON) | `Network/RBNReporter.swift` | [wave-owl `rbn_reporter.py`](https://github.com/gerolfziegenhain/wave-owl/blob/main/src/rbn_reporter.py) | MIT | RBN Aggregator v6.7 |
| WSPRNet Reporter (HTTP) | `Network/WSPRNetReporter.swift` | [wave-owl `wsprnet_reporter.py`](https://github.com/gerolfziegenhain/wave-owl/blob/main/src/wsprnet_reporter.py) | MIT | URL-encoded POST |
| Winlink Telnet | `Network/WinlinkTelnet.swift` | wl2k-go [`transport/telnet`](https://github.com/la5nta/wl2k-go/tree/master/transport/telnet) | MIT | TCP to CMS servers |
| Winlink P2P | `Network/WinlinkP2P.swift` | [la5nta/pat](https://github.com/la5nta/pat) | MIT | Direct station-to-station |
| Winlink position | `Network/WinlinkPosition.swift` | la5nta/pat | MIT | GPS position reports |
| CMS Gateway API | `Network/CMSGatewayAPI.swift` | la5nta/pat | MIT | RMS gateway directory |

## Hardware Protocol References

| Hardware | Documentation | Notes |
|----------|--------------|-------|
| (tr)uSDX | [dl2man.de](https://dl2man.de/5-trusdx-details/) | Kenwood TS-480 CAT subset, `UA1;` serial audio streaming |
| Digirig Mobile | [digirig.net](https://digirig.net/) | USB Audio Class (CM108B), VID `0x10C4` |

## Standards

| Standard | Used In | Notes |
|----------|---------|-------|
| FT8 protocol | `Codec/FT8/` | Franke & Taylor (2016), WSJT-X implementation |
| JS8Call protocol | `Codec/JS8/` | Jordan Sherer KN4CRD, based on FT8 |
| WSPR protocol | `Codec/WSPR/` | Joe Taylor K1JT, WSJT-X |
| ARDOP protocol | `Codec/ARDOP/` | Rick Muething KN6KB |
| Winlink B2F | `Network/WinlinkProtocol.swift` | Winlink Development Team |
| ITU-R M.1677 | `Codec/CW/morse_table.c` | International Morse code standard |
| Hamlib CAT | `Serial/HamlibRig.swift` | [hamlib.github.io](https://hamlib.github.io/) |

## Key Constants

| Constant | Value | Source | Used In |
|----------|-------|--------|---------|
| Costas array (FT8/JS8) | `[3,1,4,0,6,5,2]` | FT8 standard | `FT8Protocol.swift`, `JS8Protocol.swift` |
| Gray code map (8-FSK) | `[0,1,3,2,5,6,4,7]` | FT8 standard | `FT8Protocol.swift`, `JS8Protocol.swift` |
| LDPC parity check matrix | 83×7 indices | WSJT-X `ldpc_174_91_c_reordered_parity.f90` | `ft8_lib/constants.h` |
| LDPC generator matrix | 83×12 bytes | WSJT-X | `ft8_lib/constants.c` |
| WSPR conv. polynomials | 0xF2D05351, 0xE4613C47 | WSJT-X | `WSPRProtocol.swift` |
| RS primitive polynomial | 0x11D | ARDOP spec | `ARDOPReedSolomon.swift` |
| CRC-14 polynomial | 0x2757 | ft8_lib | `FT8CRC.swift`, `JS8CRC.swift` |
| CRC-16 polynomial | 0x1021 | ARDOP spec | `ARDOPCRC.swift` |

## Publications

- Franke, S. & Taylor, J. H. (2016). *The FT8 Communication Protocol*. QEX, ARRL.
- Taylor, J. H. (2005). *The WSPR Protocol*. [physics.princeton.edu/pulsar/k1jt/wspr.html](https://physics.princeton.edu/pulsar/k1jt/wspr.html)
- Sherer, J. KN4CRD. *JS8Call — Weak Signal Keyboard to Keyboard Messaging*. [js8call.com](http://js8call.com/)
- Muething, R. KN6KB. *ARDOP — Amateur Radio Digital Open Protocol*. [ardop.groups.io](https://ardop.groups.io/)
- Okumura, H. & Yoshizaki, H. (1989). *LZHUF compression*. (used in Winlink B2F)

<!-- KI generiert von Gerolf Ziegenhain -->
