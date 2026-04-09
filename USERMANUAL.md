# DigiFox — User Manual

> **DigiFox** is an iOS app for digital amateur radio modes — FT8, JS8Call, CW, WSPR, and Winlink email — all from your iPhone or iPad via a single USB-C cable.

---

## Table of Contents

1. [Getting Started](#1-getting-started)
2. [Hardware Setup](#2-hardware-setup)
3. [Station Settings](#3-station-settings)
4. [FT8 Mode](#4-ft8-mode)
5. [JS8Call Mode](#5-js8call-mode)
6. [CW Mode](#6-cw-mode)
7. [WSPR Mode](#7-wspr-mode)
8. [Winlink — Email over Radio](#8-winlink--email-over-radio)
9. [Spot Reporting](#9-spot-reporting)
10. [Troubleshooting](#10-troubleshooting)
11. [Supported Rigs](#11-supported-rigs)

---

## 1. Getting Started

### What You Need

- **iPhone or iPad** with **iOS 17** or later and a **USB-C** port
- A **ham radio transceiver** with USB connectivity (e.g., via Digirig Mobile or (tr)uSDX)
- A valid **amateur radio license** and callsign

### First Launch

1. Install DigiFox on your device.
2. Open the app — you will see the main screen with tabs for **FT8**, **JS8**, **CW**, **WSPR**, and **Winlink**.
3. Go to **Settings** (gear icon) and enter your **callsign** and **grid locator** before doing anything else.
4. Connect your transceiver via USB-C (see [Hardware Setup](#2-hardware-setup)).
5. Select your operating mode from the tab bar and start listening!

### Audio Permissions

DigiFox needs microphone access to process incoming audio from your transceiver (even though audio comes over USB, iOS treats it as a microphone input). Grant permission when prompted.

---

## 2. Hardware Setup

DigiFox supports three audio routing modes, automatically selected in this priority order:

| Priority | Device | Audio Path | How It's Detected |
|----------|--------|------------|-------------------|
| **1** | Digirig Mobile | USB Audio (CM108B soundcard) | Automatically via USB audio port |
| **2** | (tr)uSDX | Serial audio over CAT connection | Automatically via USB scan (VID `0x1A86`) |
| **3** | No external device | iPhone built-in microphone/speaker | Fallback |

### Option A: Digirig Mobile

The [Digirig Mobile](https://digirig.net/) is a compact USB interface that provides both audio and CAT serial control for your transceiver.

1. Connect the Digirig to your iPhone/iPad via a **USB-C cable** (use an adapter if your Digirig has micro-USB).
2. Connect the Digirig's audio and serial cables to your transceiver.
3. DigiFox will **auto-detect** the Digirig (Silicon Labs CP2102, VID `0x10C4`).
4. In Settings, select your **rig model** from the Hamlib list (default is FT-817).
5. The baud rate will be set automatically based on the selected rig model (default: 38,400 for FT-817).

### Option B: (tr)uSDX

The [(tr)uSDX](https://dl2man.de/) is a compact QRP transceiver that sends both CAT control and audio over a single USB-C serial connection.

1. Connect the (tr)uSDX directly to your iPhone/iPad via **USB-C**.
2. DigiFox will **auto-detect** the (tr)uSDX (QinHeng CH340/CH341, VID `0x1A86`).
3. The baud rate is fixed at **115,200** (required for audio streaming) — no configuration needed.
4. The rig model is automatically set to **TS-480** (Hamlib model 2028, Kenwood protocol).
5. Audio is streamed as serial data — no separate sound card required.

### Option C: Built-in Audio (No External Device)

If no USB device is connected, DigiFox falls back to the iPhone's built-in microphone and speaker. This is useful for:

- **Testing** the app without a radio connected
- **Acoustic coupling** (holding the phone near the radio speaker — not recommended for reliable decoding)

> **Tip:** For best results, always use a Digirig or (tr)uSDX. Built-in audio is a fallback only.

---

## 3. Station Settings

Open **Settings** from the gear icon or the settings tab. Configure these before operating:

### Essential Settings

| Setting | Description | Example |
|---------|-------------|---------|
| **Callsign** | Your amateur radio callsign | `DL1ABC` |
| **Grid Locator** | Your Maidenhead grid square (4 or 6 characters) | `JN49dx` |
| **Rig Model** | Your transceiver model (from Hamlib list) | `FT-817` (model 1020) |
| **Baud Rate** | Serial communication speed (auto-set per rig model) | `38400` |

### Additional Settings

| Setting | Description | Default |
|---------|-------------|---------|
| **TX Power (Watts)** | Your transmit power — reported to spotting networks | `5` |
| **Antenna** | Your antenna description — sent to PSK Reporter | *(empty)* |
| **PSK Reporter** | Enable automatic spot reporting | Off |
| **RBN Reporter** | Enable Reverse Beacon Network reporting | Off |
| **WSPRnet Reporter** | Enable WSPRnet spot reporting | Off |

### Rig Model Selection (Digirig Mode)

When using a Digirig, you need to select your specific transceiver model:

1. Go to **Settings** → **Rig Model**.
2. Browse or search the list (~400 supported models).
3. Select your rig — the baud rate will auto-update to the recommended value.
4. You can manually override the baud rate if needed.

> **Note:** The default rig model is **Yaesu FT-817** (Hamlib model 1020). If you use a different radio, make sure to change this.

---

## 4. FT8 Mode

FT8 (Franke-Taylor design, 8-FSK modulation) is the most popular digital mode for making quick contacts. DigiFox is fully compatible with WSJT-X.

### How FT8 Works

- FT8 operates in **15-second cycles** synchronized to UTC time
- Messages are very short (max 77 bits of payload — typically callsigns, grid, and signal report)
- Each transmission takes about **12.6 seconds** within the 15-second window
- Bandwidth is only ~50 Hz per signal

### Receiving FT8

1. Switch to the **FT8** tab.
2. Make sure your rig is tuned to an FT8 frequency (e.g., 14.074 MHz for 20m).
3. Set your rig to **USB** mode (Upper Sideband).
4. The **waterfall display** shows activity in real-time — you'll see colored traces for active signals.
5. Every 15 seconds, the decoder runs automatically and decoded messages appear in the **Band Activity** list.

### Transmitting FT8

1. Tap on a station in the **Band Activity** list to start a QSO, or enter a callsign manually in the **QSO panel**.
2. DigiFox will prepare the appropriate message (CQ, signal report, 73, etc.).
3. Tap **Transmit** — DigiFox will:
   - Activate PTT on your transceiver via CAT control
   - Send the modulated audio signal
   - Release PTT when transmission is complete

### Auto-Sequencing

DigiFox supports **automatic QSO sequencing**:

1. When enabled, DigiFox automatically selects the next appropriate message in the exchange:
   - **CQ** → other station responds → **signal report** → **RR73/73**
2. The standard FT8 exchange is:
   - Station A: `CQ DL1ABC JN49`
   - Station B: `DL1ABC DL2XYZ JO31`
   - Station A: `DL2XYZ DL1ABC -12` (signal report)
   - Station B: `DL1ABC DL2XYZ R-15` (signal report acknowledgement)
   - Station A: `DL2XYZ DL1ABC RR73` (confirmed, best regards)
   - Station B: `DL1ABC DL2XYZ 73`

### Band Activity

The Band Activity panel shows all decoded messages from the current cycle. Information displayed:

- **UTC time** of the decode
- **SNR** (Signal-to-Noise Ratio in dB)
- **Frequency offset** (Hz within the audio passband)
- **Message content** (callsigns, grid, signal reports)

Messages directed to your callsign are **highlighted** for easy identification.

---

## 5. JS8Call Mode

JS8Call is a keyboard-to-keyboard messaging mode built on FT8's modulation but designed for **free-text conversation** and **store-and-forward messaging**.

### Speed Modes

JS8Call supports five speed modes with different trade-offs between speed and sensitivity:

| Speed | Cycle Time | Best For |
|-------|-----------|----------|
| **Slow** | 30 seconds | Weak signals, long-distance |
| **Normal** | 15 seconds | Standard operation (recommended) |
| **Fast** | 10 seconds | Good signals, faster conversation |
| **Turbo** | 6 seconds | Strong signals, rapid exchange |
| **Ultra** | 60 seconds | Extremely weak signals, beacons |

### Receiving JS8

1. Switch to the **JS8** tab.
2. Tune your rig to a JS8Call frequency (e.g., 14.078 MHz for 20m).
3. Select your desired **speed mode** (Normal is recommended to start).
4. Decoded messages appear in the message list as they are received.

### Transmitting JS8

1. Type your message in the **text input field**.
2. Select the destination callsign or use `@ALLCALL` for a general broadcast.
3. Tap **Transmit** to send your message.
4. JS8Call supports sending longer free-text messages by splitting them across multiple transmissions automatically.

### Key Differences from FT8

- **Free-text messaging** — you can type any message, not just standard exchanges
- **Variable speed** — choose faster or slower modes depending on conditions
- **Store-and-forward** — messages can be relayed through other JS8Call stations
- **Heartbeat** — stations can send periodic heartbeats to announce their presence

---

## 6. CW Mode

DigiFox includes a full **CW (Morse Code)** mode with both a decoder and a keyer.

### CW Decoder

The decoder uses the [ggmorse](https://github.com/ggerganov/ggmorse) library for automatic Morse code decoding:

- **Automatic pitch detection** — works across 200–1200 Hz
- **Automatic speed detection** — decodes 5–55 WPM (Words Per Minute)
- **Real-time waterfall** — a monochrome waterfall display shows CW signals
- No manual tuning required — the decoder adapts to the incoming signal

### Using CW Decode

1. Switch to the **CW** tab.
2. Tune your rig to a CW frequency (e.g., 14.000–14.070 MHz on 20m).
3. Set your rig to **CW** mode.
4. Decoded text appears in real-time as Morse signals are received.
5. The waterfall display helps you visually identify and follow CW signals.

### CW Keyer (Transmit)

1. Type your message in the text field.
2. Tap **Transmit** — DigiFox sends the Morse code via your transceiver's CW keying input (through Hamlib CAT control or direct serial keying).
3. For zero-latency keying, DigiFox can use direct POSIX serial writes to the keying line.

---

## 7. WSPR Mode

WSPR (Weak Signal Propagation Reporter) is a beacon mode for testing propagation paths using very low power.

### How WSPR Works

- WSPR transmissions are **120 seconds long** (2 minutes), starting on even minutes UTC
- Extremely narrow bandwidth (~6 Hz) and strong error correction allow decoding signals far below the noise floor
- WSPR messages contain only: **callsign**, **grid locator**, and **transmit power**
- Typically used with very low power (e.g., 1–5 watts)

### Receiving WSPR

1. Switch to the **WSPR** tab.
2. Tune your rig to a WSPR frequency (e.g., 14.0956 MHz for 20m).
3. Set your rig to **USB** mode.
4. The decoder processes 2-minute windows and displays decoded beacons with:
   - Callsign of the transmitting station
   - Grid locator
   - Transmit power
   - SNR (Signal-to-Noise Ratio)

### Transmitting WSPR (Beacon Mode)

1. Ensure your **callsign**, **grid locator**, and **TX power** are set in Settings.
2. Enable beacon mode in the WSPR tab.
3. DigiFox will transmit your WSPR beacon on even-minute boundaries.

> **Important:** WSPR is a beacon mode — it transmits automatically. Make sure you are using an appropriate power level and that you are permitted to transmit on the selected frequency.

### WSPRnet Reporting

When **WSPRnet Reporter** is enabled in Settings, decoded WSPR spots are automatically uploaded to [wsprnet.org](https://wsprnet.org) so other operators worldwide can see your reception reports. See [Spot Reporting](#9-spot-reporting) for details.

---

## 8. Winlink — Email over Radio

DigiFox includes a full **Winlink** email client, allowing you to send and receive email over radio — useful for emergency communications or operating from locations without internet access.

### Connection Modes

| Mode | Transport | Requirements |
|------|-----------|-------------|
| **Telnet** | Internet (TCP/IP) | Wi-Fi or cellular data connection |
| **ARDOP (HF)** | Radio (ARQ over HF) | HF transceiver, antenna |
| **P2P (Direct)** | Radio (station-to-station) | Both stations running Winlink |

### Getting Started with Winlink

1. Switch to the **Winlink** tab.
2. Your Winlink account uses your **amateur radio callsign** as your email address (e.g., `DL1ABC@winlink.org`).
3. Account credentials are stored securely in the iOS Keychain.

### Sending Email via Telnet (Internet)

This is the easiest way to test Winlink:

1. Make sure your device has an internet connection.
2. In the Winlink tab, select **Telnet** as the connection mode.
3. Tap **Connect** — DigiFox connects to the Winlink CMS server (`server.winlink.org:8772`).
4. Compose a new message with recipient, subject, and body.
5. Tap **Send** — the message is transferred using the B2F protocol.

### Sending Email via HF (ARDOP)

For true radio email without internet:

1. Select **ARDOP** as the connection mode.
2. DigiFox uses its built-in ARDOP modem (no external TNC needed).
3. Select a gateway station from the RMS gateway directory, or enter one manually.
4. Tap **Connect** — DigiFox establishes an ARQ (Automatic Repeat Request) session with the gateway.
5. Messages are exchanged using the B2F protocol with LZHUF compression.

### P2P (Direct Station-to-Station)

For direct communication with another Winlink station without a gateway:

1. Select **P2P** as the connection mode.
2. Enter the other station's callsign.
3. Both stations must be on the same frequency and running Winlink.
4. DigiFox establishes a direct ARDOP ARQ session and exchanges messages using B2F protocol.

### Composing Messages

- Tap **New Message** to compose.
- Enter the **recipient** (email address or callsign@winlink.org).
- Add a **subject** and **message body**.
- **Attachments** are supported but should be kept small for HF transfer (LZHUF compression is applied automatically).
- Messages are stored locally in a **JSON mailbox** on your device.

### Position Reports

DigiFox can send GPS position reports via Winlink, useful for tracking and emergency coordination. The app uses iOS Location Services to determine your position.

---

## 9. Spot Reporting

DigiFox can automatically report decoded stations to global spotting networks. This helps the amateur radio community track propagation conditions worldwide.

### Supported Networks

| Network | What It Reports | Protocol |
|---------|----------------|----------|
| **[PSK Reporter](https://pskreporter.info)** | FT8, JS8 decodes | IPFIX/UDP binary |
| **[Reverse Beacon Network](https://reversebeacon.net)** | CW, FT8 spots | HTTP POST JSON |
| **[WSPRnet](https://wsprnet.org)** | WSPR beacon spots | HTTP POST |

### Enabling Spot Reporting

1. Go to **Settings**.
2. Toggle on the networks you want to report to:
   - **PSK Reporter** — for FT8 and JS8 spots
   - **RBN** — for CW and FT8 spots
   - **WSPRnet** — for WSPR spots
3. Make sure your **callsign** and **grid locator** are correctly set — these are sent with every report.
4. Optionally set your **antenna** description (sent to PSK Reporter).

### How It Works

- Spot reporting happens **automatically** in the background.
- Every time DigiFox decodes a message, it sends the spot data to the enabled networks.
- **PSK Reporter** batches spots and flushes every 5 minutes.
- **RBN** sends spots every 10 seconds.
- **WSPRnet** sends each spot individually with a short delay.
- No separate login or registration is needed — your callsign and grid are sufficient.

> **Note:** All reporters are **disabled by default**. Enable them only when you are actively monitoring and want to contribute reception reports.

---

## 10. Troubleshooting

### No Audio / No Decodes

| Symptom | Possible Cause | Solution |
|---------|---------------|----------|
| Waterfall is blank | USB device not detected | Unplug and replug the USB-C cable. Check that the Digirig or (tr)uSDX is powered on. |
| Waterfall shows noise but no decodes | Wrong frequency or mode | Verify you are on the correct digital mode frequency and that your rig is set to USB (for FT8/JS8/WSPR). |
| Waterfall shows signals but no decodes | Clock not synchronized | FT8 and WSPR require accurate time sync. Make sure your iPhone's time is set automatically (Settings → General → Date & Time → Set Automatically). |
| Audio is distorted | Levels too high | Reduce your rig's audio output level or adjust the AF gain. |
| Audio cuts out intermittently | USB connection loose | Ensure a solid USB-C connection. Try a different cable. |

### PTT Not Working

| Symptom | Possible Cause | Solution |
|---------|---------------|----------|
| Rig does not transmit | Wrong rig model selected | Go to Settings and verify the correct rig model is selected for your transceiver. |
| PTT activates but no audio | Audio routing incorrect | Make sure the Digirig audio cables are connected to your rig's data port (not the mic jack). |
| PTT toggles rapidly | CAT command conflict | Check the baud rate matches your rig's serial configuration. |
| "No rig connected" error | Serial connection failed | Unplug/replug USB. Verify the correct baud rate in Settings. |

### Connection Problems

| Symptom | Possible Cause | Solution |
|---------|---------------|----------|
| Digirig not detected | Cable or adapter issue | Use a USB-C cable that supports data (not charge-only). Try a different cable. |
| (tr)uSDX not detected | Driver issue | The CH340/CH341 chip should be auto-detected. Try unplugging and reconnecting. |
| Winlink Telnet fails | No internet | Check Wi-Fi or cellular connection. Fallback server: `cms.winlink.org:8772`. |
| ARDOP session fails | Weak signal | Move to a frequency with less QRM. Try a different gateway station. |

### General Tips

- **Restart the app** if audio routing seems stuck after plugging/unplugging USB devices.
- **Check the debug log** (Log Output view) for detailed diagnostic messages — every significant operation is logged with timestamps.
- **Time synchronization** is critical for FT8 and WSPR. iOS normally keeps accurate time via NTP, but verify if you experience decode failures.
- **USB-C hubs** may cause issues — connect the Digirig or (tr)uSDX directly when possible.
- The app is designed for **USB-C devices only** — Lightning-based iPhones/iPads are not supported.

---

## 11. Supported Rigs

### Hamlib Rig Control

DigiFox uses [Hamlib](https://hamlib.github.io/) (Ham Radio Control Libraries) to support approximately **400 transceiver models** from all major manufacturers. Hamlib provides:

- **Frequency control** — set and read VFO frequency
- **Mode control** — switch between USB, LSB, CW, AM, FM, DATA modes
- **PTT control** — activate/deactivate transmit via RTS serial line
- **CW keying** — Morse code keying for CW mode

### Default Configuration

| Setting | Value | Notes |
|---------|-------|-------|
| Default rig model | **Yaesu FT-817** (Hamlib model 1020) | Change in Settings if using a different rig |
| Default baud rate | **38,400** (Digirig) / **115,200** ((tr)uSDX) | Auto-set per rig model; can be overridden |
| PTT method | RTS serial line | Standard for Digirig |

### Specifically Tested Hardware

| Device | Connection | Protocol | Notes |
|--------|-----------|----------|-------|
| **Yaesu FT-817/818** | Digirig USB-C | Hamlib (model 1020) | Default rig, well-tested |
| **(tr)uSDX** | Direct USB-C | Kenwood TS-480 (model 2028) | Audio + CAT over single serial cable, 115200 baud |
| **Digirig Mobile** | USB-C | USB Audio + CP2102 serial | Works with any Hamlib-supported rig |

### Popular Rig Models

While DigiFox supports ~400 models via Hamlib, here are some commonly used ones:

| Manufacturer | Model | Hamlib Model ID |
|-------------|-------|----------------|
| Yaesu | FT-817 / FT-818 | 1020 |
| Yaesu | FT-891 | 1037 |
| Yaesu | FT-991A | 1036 |
| Icom | IC-7300 | 3073 |
| Icom | IC-705 | 3085 |
| Kenwood | TS-480 | 2028 |
| Kenwood | TS-590SG | 2026 |
| Elecraft | K3 | 2036 |
| Elecraft | KX3 | 2043 |

> **Tip:** If your rig is not listed, browse the full Hamlib model list in Settings. Most modern HF transceivers with a CAT (Computer Aided Transceiver) port are supported.

---

## Quick Reference — Frequencies

Common digital mode frequencies (dial frequency, USB):

| Band | FT8 | JS8Call | WSPR | CW |
|------|-----|---------|------|----|
| 160m | 1.840 MHz | 1.842 MHz | 1.8366 MHz | 1.800–1.840 MHz |
| 80m | 3.573 MHz | 3.578 MHz | 3.5926 MHz | 3.500–3.570 MHz |
| 40m | 7.074 MHz | 7.078 MHz | 7.0386 MHz | 7.000–7.040 MHz |
| 30m | 10.136 MHz | 10.130 MHz | 10.1387 MHz | 10.100–10.130 MHz |
| 20m | 14.074 MHz | 14.078 MHz | 14.0956 MHz | 14.000–14.070 MHz |
| 17m | 18.100 MHz | 18.104 MHz | 18.1046 MHz | 18.068–18.095 MHz |
| 15m | 21.074 MHz | 21.078 MHz | 21.0946 MHz | 21.000–21.070 MHz |
| 12m | 24.915 MHz | 24.922 MHz | 24.9246 MHz | 24.890–24.915 MHz |
| 10m | 28.074 MHz | 28.078 MHz | 28.1246 MHz | 28.000–28.070 MHz |

---

## Disclaimer

DigiFox is experimental software developed with the assistance of AI. Use at your own risk. Always ensure you comply with your local amateur radio regulations and licensing requirements when transmitting.

---

*73 and good DX!*

<!-- KI generiert von Gerolf Ziegenhain -->
