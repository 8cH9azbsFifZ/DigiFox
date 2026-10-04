**Status: DEFERRED.** These are future requirements, not claims about the current app. Do not implement or sync into main specifications until the user explicitly resumes the change and the serial-access blocker is resolved.

## ADDED Requirements

### Requirement: Support both iPhone and iPad
The selected production solution SHALL support both iPhone and iPad. An iPad-only DriverKit transport MUST NOT be presented as satisfying this requirement. Any bridge that changes the direct USB topology SHALL require explicit user approval.

#### Scenario: Only an iPad transport is feasible
- **WHEN** direct serial access is verified on an M-series iPad but not on iPhone
- **THEN** the overall cross-platform goal remains unresolved and no bridge topology is selected without user approval

### Requirement: Deferred implementation gate
The change MUST remain deferred until the user explicitly resumes it. Completing planning artifacts SHALL NOT trigger driver implementation, entitlement submission or serial-profile activation.

#### Scenario: Serial access remains unavailable
- **WHEN** planning is complete but the change has not been explicitly resumed
- **THEN** implementation tasks remain unchecked and Hermes runtime behavior remains unchanged

### Requirement: Verified Apple serial capability
The system SHALL expose direct USB serial control only through a verified, public-API transport supported on the current Apple hardware and OS, with the required provisioning and driver authorization. Compilation or device enumeration alone MUST NOT imply usable serial access.

#### Scenario: Unsupported platform
- **WHEN** no verified direct serial transport exists on the user's iPhone or iPad
- **THEN** direct serial control is unavailable with a German explanation, without silently selecting a bridge or claiming CAT connectivity

#### Scenario: Supported iPad with disabled driver
- **WHEN** a supported M-series iPad has the required extension installed but not enabled
- **THEN** serial control remains unavailable and the user is directed to the iPad driver settings

### Requirement: Correct Digirig transceiver configuration
The system SHALL distinguish the Digirig interface from the attached radio model and use verified device identity, user-selected radio model, matching serial parameters and an explicitly selected PTT method. It MUST NOT classify every Silicon Labs device as a verified Digirig.

#### Scenario: Radio through Digirig
- **WHEN** a verified Digirig transport is available and the user selects a supported radio and matching serial settings
- **THEN** the system performs a bounded CAT handshake before publishing a connected rig state

### Requirement: Exclusive serial transport ownership
The system SHALL use one owner for the opened transport, serialized CAT requests and modem-line control, with timeout, cancellation and explicit error reporting. A non-POSIX USB identifier MUST NOT be passed to a pathname-based Hamlib open operation.

#### Scenario: CAT and RTS share a device
- **WHEN** CAT requests and an RTS PTT transition target the same Digirig
- **THEN** they use the same transport owner without duplicate device opens or hardware-flow-control changes to RTS

#### Scenario: CAT response times out
- **WHEN** the radio does not respond within the configured bounded timeout
- **THEN** the operation reports a diagnostic error and does not publish a successful handshake

### Requirement: Explicit and fail-aware PTT
The system SHALL keep PTT inactive when connecting, use CAT or RTS only as explicitly configured, and disable RTS/CTS flow control for RTS-based PTT. On TX cancellation or connection failure it SHALL stop TX audio and attempt PTT release while the transport remains reachable; an unconfirmed release MUST produce a user-visible warning.

#### Scenario: Digirig hardware PTT
- **WHEN** the user starts and finishes TX with verified RTS PTT wiring
- **THEN** RTS is explicitly asserted for TX and deasserted afterward without unrelated handshake toggles

#### Scenario: Device removed during TX
- **WHEN** the USB device is removed while transmitting
- **THEN** audio and queued TX stop, the rig becomes disconnected, and any inability to confirm PTT release is explicitly reported

### Requirement: Independent USB audio and CAT states
The system SHALL track audio routing independently from serial availability and preserve the 12 kHz internal codec rate for both FT8 and JS8, resampling native hardware audio at the boundary.

#### Scenario: Audio available without CAT
- **WHEN** Digirig USB audio is available but serial control is unavailable
- **THEN** the app does not report CAT-connected status or enable serial-dependent TX solely because audio was detected

#### Scenario: Hardware audio rate differs
- **WHEN** a verified device supplies audio at a native rate other than 12 kHz
- **THEN** FT8 and JS8 receive 12 kHz samples and TX is converted to the negotiated hardware rate

### Requirement: Optional independent QMX validation
QMX support SHALL remain optional and deferred until separately approved, with verified USB descriptors, firmware-specific CAT commands and PTT capabilities. QMX MUST NOT be treated as a CP210x Digirig or require an external Digirig for its built-in USB interfaces.

#### Scenario: QMX evaluation approved after resumption
- **WHEN** the user authorizes QMX evaluation and provides the device firmware and descriptors
- **THEN** the plan selects the appropriate USB transport and validates supported CAT operations independently

### Requirement: Preserve Hermes compatibility
The system SHALL retain the existing Hermes connection path and settings during deferral and after serial support is introduced, without forcing existing Hermes users onto a serial profile.

#### Scenario: Existing Hermes user
- **WHEN** a user retains the Hermes profile
- **THEN** discovery, RX and TX continue without requiring a serial extension or accessory
