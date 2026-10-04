## Context

**Status: DEFERRED.** Documentation only. All technical choices below are planned or conditional; no driver, entitlement request or runtime change is authorized until the user explicitly resumes the change.

The primary target is a transceiver connected through Digirig Mobile. QMX is a potential second target, not a committed deliverable. The exact Apple device, transceiver, Digirig revision/configuration and QMX firmware are not yet known.

The user requires both iPhone and iPad support. An M-series-iPad-only implementation does not meet the overall goal; no alternative hardware/topology has been approved.

The current code contains two different paths: `SerialPort` wraps `IOKitUSBSerial`, while `CATController` opens Hamlib directly using a pathname. On a physical iOS device, `IOKitUSBSerial` delegates `usb:VID:PID` paths to `CP2102USBDriver`; this does not give Hamlib a working serial file descriptor. `CP2102USBDriver` also uses hard-coded USB user-client selectors and endpoint assumptions. These are not evidence of a supported, sandbox-permitted USB transport.

The current macOS-style `com.apple.security.device.usb` entitlement does not establish iPhone USB access. IOKit header/link availability, successful registry enumeration, a simulator result and an actual device open/read/write are separate milestones.

### Digirig hardware specification and source record

Research date: 2026-10-04. Summary of manufacturer documentation, not a substitute for the exact unit's schematic.

| Component | Documented behavior | Consequence for DigiFox |
|---|---|---|
| Host connection | One USB-C connection provides power and communications through an internal USB hub | Discover serial and audio separately; verify adequate power |
| Audio | CM108-based USB sound card | Use system audio APIs, independent of CAT access |
| Serial | CP2102 USB-to-UART bridge | Implement CP210x vendor requests, not USB CDC requests |
| Identification | Existing code expects Silicon Labs VID `0x10C4`, PID `0xEA60` | Treat these as candidate identifiers; capture actual descriptors before an Apple request; VID alone is not proof of Digirig |
| Hardware PTT | Serial RTS drives an open-collector switch to ground; audio socket ring 2 from revision 1.6 onward | Explicit RTS PTT ownership; disable RTS/CTS hardware flow control; no automatic RTS assertion |
| CAT | Bytes pass through to the connected radio; Digirig has no universal CAT command language | Select the actual transceiver/Hamlib model and its serial settings |
| Electrical configuration | 0-3.3 V duplex logic, RS-232, Icom half-duplex CI-V, or TX-500 configuration | Hardware/cable selection must match the radio; an app setting cannot change solder jumpers |
| Connectors | Separate 3.5 mm TRRS audio/PTT and serial sockets | Use the manufacturer schematic and radio-specific cable pinout; do not infer wiring from connector shape |

Manufacturer sources:

- [Getting started, components, PTT and serial setup](https://digirig.net/getting-started-with-digirig-mobile/)
- [Revision 1.9 electrical configuration and schematic](https://digirig.net/digirig-mobile-rev-1-9/)
- [Selecting a serial configuration](https://digirig.net/selecting-digirig-configuration/)
- [Open hardware repository](https://github.com/softcomplex/Digirig-Mobile)
- [KiCad schematic](https://github.com/softcomplex/Digirig-Mobile/blob/main/electric/digirig-mobile/digirig-mobile.kicad_sch)
- [Silicon Labs CP210x driver resources](https://www.silabs.com/developers/usb-to-uart-bridge-vcp-drivers)

QMX has its own USB sound card and USB virtual COM CAT port. Its manufacturer specifies 24-bit, 48 ksps audio. Capture the actual interface descriptors before choosing a CDC implementation, and use the CAT manual for the installed firmware rather than assuming CP210x or a fully compatible generic Kenwood implementation.

- [QMX hardware, firmware and manuals](https://qrp-labs.com/qmx.html)
- [QMX CAT manual for firmware 1_04_004 and above](https://qrp-labs.com/images/qmx/manuals/cat_1_04_004.pdf)

## Goals / Non-Goals

**Goals:** Plan public-API, distribution-compatible serial CAT and safe PTT; keep audio and serial capability separate; preserve Hermes; keep optional QMX work gated by independent validation.

**Non-Goals:** Implement while deferred; promise direct iPhone USB serial access; rely on private USB selectors or jailbreaks; silently introduce a network/BLE bridge; rewrite the FT8/JS8 codecs; assume all Digirig revisions or QMX firmware behave identically.

## Decisions

### 1. Resolve the Apple platform gate first

Apple documents DriverKit/USBDriverKit on M-series iPads, not on iPhone. The candidate direct-USB route is therefore an iPad DriverKit extension plus app-facing user client, conditional on hardware testing and Apple-approved provisioning.

For iPhone, no supported generic USB serial route has been established. Ask Apple Developer Technical Support to confirm the current public API position. An entitlement request is not a promise that Apple can enable an otherwise unavailable platform feature. ExternalAccessory requires compatible MFi hardware and a manufacturer-supported protocol; it does not turn an ordinary CP2102 into an MFi accessory.

Alternatives, only after a separate user decision: a BLE GATT serial bridge or a network CAT service (for example, a separately configured rigctld host). Generic Bluetooth Classic SPP is not assumed to work on iPhone. A bridge changes the single-cable topology and may require a separate audio solution.

### 2. Contact Apple through the developer channels

All contact actions remain DEFERRED; none have been submitted.

1. Open [code-level support](https://developer.apple.com/contact/request/code-level-support/) using the Developer Program account. Ask separately about iPhone direct USB serial and M-series iPad USBDriverKit. Provide exact device/OS, a minimal public-API reproduction, error codes and descriptor capture if available. Do not claim a test failure that has not been observed.
2. For the iPad route, use the [DriverKit entitlement request](https://developer.apple.com/contact/request/system-extension/), linked from Apple's System Extensions page.
3. Supply DigiFox's bundle identifier `com.digifox.app`, developer team, intended driver bundle ID (not assigned yet), device description, verified VID/PID/interface matching and TestFlight/App Store distribution intent. Explain that the app developer is not the USB hardware vendor, and ask whether vendor consent is required.
4. Request the driver entitlements `com.apple.developer.driverkit` and `com.apple.developer.driverkit.transport.usb` for the precise supported hardware. For the iPad host app, clarify provisioning for `com.apple.developer.driverkit.communicates-with-drivers`. Do not request SerialDriverKit solely because the payload is serial bytes: the planned custom USB user client does not depend on a BSD serial device.
5. After approval, configure the extension App ID, entitlement group and separate provisioning profile; update signing/export to include the extension. iPadOS does not use macOS's SystemExtensions activation API. The user enables the driver under Settings > General > Drivers.

Suggested technical questions for the support form:

> DigiFox is an iPhone/iPad amateur-radio app (com.digifox.app). We want to exchange CAT bytes with a transceiver through a Digirig Mobile CP2102 USB-UART interface and control its RTS-based PTT while using the separate USB audio interface. QRP Labs QMX, with built-in USB audio and virtual COM CAT, is a possible future target. Is there a supported public API for direct access to these non-MFi USB serial interfaces on iPhone? For M-series iPads, is a USBDriverKit extension with an app-facing user client the supported approach, and which entitlements and provisioning are required for TestFlight/App Store distribution? We are not the hardware vendor; what hardware-vendor authorization and device matching information do you require?

Apple references:

- [Creating drivers for iPadOS: hardware support, activation and user-client entitlement](https://developer.apple.com/documentation/driverkit/creating-drivers-for-ipados)
- [Requesting DriverKit entitlements](https://developer.apple.com/documentation/driverkit/requesting-entitlements-for-driverkit-development)
- [USB transport entitlement and matching keys](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.driverkit.transport.usb)
- [ExternalAccessory limitations](https://developer.apple.com/documentation/externalaccessory)
- [Code-level support process](https://developer.apple.com/support/technical/)

### 3. One transport owner, independent CAT and PTT policies

Planned data path:

```text
AppState (@MainActor)
  -> CATController (actor: commands and rig state)
     -> verified Hamlib integration or bounded rig-specific CAT adapter
        -> SerialPort (actor: exclusive transport ownership)
           -> iPad driver user client
              -> USBDriverKit extension
                 -> CP2102 UART -> Digirig serial cable -> transceiver CAT
                 -> CP2102 RTS -> Digirig audio/PTT cable -> transceiver PTT

AudioEngine -> system USB audio route -> Digirig CM108 / QMX USB audio
```

The transport contract covers discovery with stable device identity, open/configure, ordered writes, bounded reads, timeout/cancellation, RTS/DTR support and close. One owner serializes CAT traffic and line control on the same device; duplicate USB claims and competing Hamlib/SerialPort opens are prohibited.

For CP210x, use documented vendor requests for UART enable/disable, baud and line coding, handshake/line state and buffers; discover bulk endpoints from descriptors. For QMX, determine the USB class first and implement that transport independently. Do not send CP210x requests to QMX.

Choose CAT-command PTT or explicit RTS PTT according to the radio/cable, not according to the USB vendor ID. DTR is not toggled unless the device-specific policy explicitly requires it. Initially perform receive-only CAT frequency reads; add writes and PTT only after the transport and wiring are verified.

### 4. Resolve Hamlib integration before production control

The vendored Hamlib opens pathname-based ports. A DriverKit user client is not a `/dev/tty` node. Before implementation, investigate supported custom transport hooks in the actual vendored version and build a small end-to-end proof.

Preferred outcome: preserve existing rig backends with a supported adapter and one transport owner. If this is not viable, decide explicitly between a bounded CAT implementation for the selected radio or a user-approved external Hamlib network bridge. Do not pass `usb:VID:PID` or a fabricated fd to `rig_open`, and do not assume an async Swift actor can be called synchronously from C without a queue/lifetime design.

### 5. Capabilities, audio and lifecycle

Track platform eligibility, driver authorization/enabled state, device discovery, transport opened, CAT handshake and USB audio route independently. Only a completed rig handshake publishes a CAT-connected state. Publish state via `@MainActor`, with bounded background I/O and actor-owned cancellation.

Keep native USB sample rates at the hardware boundary and resample to/from the existing 12 kHz codec rate. Device removal, audio-route changes, driver loss, app lifecycle changes or I/O failure cancel queued TX, stop audio and attempt PTT release if transport remains reachable. If release cannot be confirmed, show an explicit warning; never claim the radio is safely in RX. Driver-side cleanup/watchdog behavior must be verified rather than promised.

## Risks / Trade-offs

- [Apple declines the entitlement or the user's device is an iPhone/non-M iPad] -> Keep direct serial support deferred; retain Hermes; discuss a bridge only as a separate topology choice.
- [Raw IOKit calls compile but runtime access is denied] -> Require approved public APIs plus physical-device read/write evidence, not SDK availability.
- [Wrong electrical configuration damages hardware] -> Require radio-specific cable and manufacturer configuration confirmation before connecting CAT.
- [RTS handshake asserts PTT unintentionally] -> Disable hardware flow control; explicitly initialize PTT inactive and verify connect/disconnect behavior using a safe bench setup.
- [PTT becomes unreachable during disconnection] -> Stop audio, warn the user, verify hardware fail-safe behavior; do not promise software can release an inaccessible line.
- [Hamlib custom transport is unavailable] -> Make the protocol/bridge decision before further integration work.
- [Audio works while serial does not] -> Show separate capability states; do not label USB audio detection as CAT connectivity.

## Migration Plan

No migration while DEFERRED. Keep current Hermes profiles and settings behavior unchanged. After explicit resumption and successful feasibility checks, add capability-aware profile selection and update the current forced-Hermes settings migration. Existing Hermes users retain their settings. Roll back by disabling the serial feature while retaining Hermes and user preferences.

The repository currently uses a checked-in `.xcodeproj` and `generate_project.py`, with no `project.yml`. Determine the authoritative generator before adding a driver target; do not blindly run XcodeGen or overwrite project settings.

## Open Questions

- Which exact iPhone/iPad model and OS are intended? Is an M-series iPad available?
- Which transceiver, Digirig revision, electrical configuration and radio cables are in use?
- What are the verified USB IDs, interface descriptors and serial settings?
- Does Apple approve third-party hardware matching, and what vendor authorization is required?
- Can the vendored Hamlib use the proposed transport without duplicate ownership?
- Is optional QMX work wanted, and with which firmware/CAT capabilities?
- If direct USB is unavailable, is additional BLE/network hardware acceptable?
