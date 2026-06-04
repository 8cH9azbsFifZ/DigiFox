## ADDED Requirements

### Requirement: Frequency control via HPSDR C&C
The system SHALL set RX and TX NCO frequencies on the Hermes SDR via HPSDR Protocol 1 Command & Control registers.

#### Scenario: Set RX frequency
- **WHEN** user selects a band or enters a dial frequency
- **THEN** system writes the frequency (32-bit Hz, big-endian) to register address 0x02 (RX1 NCO)
- **AND** frequency change takes effect within 50ms (next EP2 cycle)

#### Scenario: Set TX frequency
- **WHEN** user initiates transmission
- **THEN** system writes TX NCO frequency to register address 0x01
- **AND** TX occurs at the specified frequency

### Requirement: PTT via MOX bit
The system SHALL control PTT (Push-To-Talk) via the MOX bit in the EP2 C0 register.

#### Scenario: Enable PTT
- **WHEN** TX audio is ready to send
- **THEN** system sets C0 bit 0 = 1 (MOX active) in EP2 frames
- **AND** Hermes switches to transmit mode

#### Scenario: Disable PTT
- **WHEN** TX audio buffer is exhausted or user aborts
- **THEN** system clears C0 bit 0 = 0 (MOX inactive)
- **AND** Hermes returns to receive mode

### Requirement: LNA gain control
The system SHALL allow user to set the Hermes LNA gain (0-60 dB).

#### Scenario: User adjusts gain
- **WHEN** user changes LNA gain slider
- **THEN** system writes gain value to register address 0x0A with bit 6 set (AD9866 extended mode)
- **AND** gain change takes effect within 50ms

### Requirement: TX drive level control
The system SHALL allow user to set the TX output power level.

#### Scenario: User adjusts TX power
- **WHEN** user changes TX power slider (0-100%)
- **THEN** system maps percentage to 0-255 hardware level
- **AND** writes to register address 0x09 bits [31:28]
