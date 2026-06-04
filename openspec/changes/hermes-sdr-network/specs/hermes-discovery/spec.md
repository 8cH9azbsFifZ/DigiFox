## ADDED Requirements

### Requirement: Network Discovery
The system SHALL discover HPSDR Protocol 1 compatible SDR devices on the local network via UDP broadcast to port 1024.

#### Scenario: Broadcast discovery on connected Ethernet
- **WHEN** user initiates SDR scan and an Ethernet adapter is connected
- **THEN** system sends discovery packet (0xEFFE02 + 57 zero bytes) as UDP broadcast
- **AND** displays all responding devices with IP, MAC, Board-ID, and Gateware version

#### Scenario: No Ethernet adapter connected
- **WHEN** user initiates SDR scan without Ethernet connectivity
- **THEN** system displays error message indicating no network interface available

#### Scenario: Multiple devices found
- **WHEN** discovery receives responses from multiple Hermes devices
- **THEN** system displays all devices in a selection list
- **AND** user can select which device to connect to

#### Scenario: Manual IP entry
- **WHEN** broadcast discovery fails (e.g. different subnet)
- **THEN** user SHALL be able to enter a device IP address manually
