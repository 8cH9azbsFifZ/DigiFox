# DigiFox

DigiFox is an iOS application that connects to amateur (ham) radio transceivers via a single USB-C cable to operate digital modes.

## Overview

DigiFox enables hams to use their iPhone or iPad as a digital mode interface by establishing a direct USB-C connection to their radio. No additional hardware or sound card interfaces are required — just plug in a USB-C cable and get on the air.

## Supported Hardware

### (tr)uSDX
The [(tr)uSDX](https://dl2man.de/) is a compact QRP transceiver that exposes both **CAT control** and **audio I/O** over a single USB-C connection:

- **USB CDC ACM** — Serial interface for CAT commands (Kenwood TS-480 protocol subset, 38400 baud, 8N1)
- **USB Audio Class** — Standard USB audio device for TX/RX digital audio

This means a single cable handles everything: rig control and audio.

## Features

- Single USB-C cable connection (CAT + audio)
- CAT control via Kenwood TS-480 protocol (frequency, mode, PTT)
- USB Audio Class I/O via AVAudioEngine
- Real-time RX audio level monitoring
- Auto-detection of USB serial ports
- SwiftUI interface for iPhone and iPad

## Architecture

```
┌──────────────┐     USB-C      ┌───────────────┐
│   DigiFox    │◄──────────────►│   (tr)uSDX    │
│   iOS App    │                │  Transceiver  │
├──────────────┤                ├───────────────┤
│ USBAudioMgr  │◄── USB Audio ──│  Audio Codec  │
│ CATController│◄── USB Serial ─│  CAT (serial) │
└──────────────┘                └───────────────┘
```

## Requirements

- iOS 17+ device with USB-C port
- (tr)uSDX transceiver (or compatible Kenwood CAT radio with USB)
- USB-C cable

## Disclaimer

This entire project has been generated using various AI models and is therefore experimental in nature. Use at your own risk.

## License

TBD
