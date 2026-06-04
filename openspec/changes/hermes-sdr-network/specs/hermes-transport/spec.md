## ADDED Requirements

### Requirement: UDP IQ Stream Reception
The system SHALL receive EP6 IQ data packets from Hermes SDR at the configured sample rate (48/96/192/384 kHz).

#### Scenario: Start IQ stream
- **WHEN** user connects to a discovered Hermes device
- **THEN** system sends HPSDR start packet (0xEFFE04 0x81)
- **AND** begins receiving EP6 packets (1032 bytes each, 2 USB frames)

#### Scenario: Parse 24-bit IQ samples
- **WHEN** an EP6 packet is received
- **THEN** system extracts 24-bit signed I and Q values from each USB frame
- **AND** normalizes them to Float [-1.0, 1.0]
- **AND** applies IQ swap configuration (default: swap=true for HL2)

#### Scenario: Stop IQ stream
- **WHEN** user disconnects or app enters background
- **THEN** system sends stop packet (0xEFFE04 0x00)
- **AND** ceases all UDP communication

#### Scenario: Watchdog keepalive
- **WHEN** IQ stream is active
- **THEN** system sends EP2 control packets at minimum every 200ms
- **AND** Hermes watchdog does not trigger disconnect

### Requirement: TX IQ Stream Transmission
The system SHALL transmit modulated IQ audio to Hermes SDR for digital mode transmission.

#### Scenario: FT8 transmission
- **WHEN** user initiates FT8 TX with encoded message
- **THEN** system converts 12 kHz real modulator output to 48 kHz IQ via Hilbert transform
- **AND** packs I/Q as 24-bit signed pairs into EP2 USB frame payload (84 samples/frame)
- **AND** sets MOX bit in C0 register
- **AND** sends EP2 packets at ~3.5ms intervals to maintain 48 kHz rate

#### Scenario: TX completion
- **WHEN** all TX audio samples have been sent
- **THEN** system clears MOX bit
- **AND** resumes normal EP2 keepalive cycle

### Requirement: Network resilience
The system SHALL handle network interruptions gracefully.

#### Scenario: Packet loss during RX
- **WHEN** EP6 packets are lost (sequence gap detected)
- **THEN** system continues decoding with available data
- **AND** logs gap count for diagnostics

#### Scenario: Ethernet adapter removed
- **WHEN** the USB-C Ethernet adapter is physically disconnected during operation
- **THEN** system detects loss via NWPathMonitor
- **AND** shows disconnect status in UI
- **AND** stops all Hermes communication cleanly
