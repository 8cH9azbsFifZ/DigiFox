## ADDED Requirements

### Requirement: IQ to baseband audio conversion
The system SHALL convert complex IQ samples from Hermes SDR to real-valued 12 kHz audio for the existing codec pipeline.

#### Scenario: Standard USB demodulation
- **WHEN** IQ samples are received at 48 kHz from Hermes (NCO set to dial frequency)
- **THEN** system extracts real part (I channel) as audio
- **AND** decimates from 48 kHz to 12 kHz using Accelerate/vDSP
- **AND** feeds result into AudioEngine.feedExternalSamples()

#### Scenario: Correct spectrum orientation
- **WHEN** IQ swap configuration is set correctly for HL2 (swap_iq=true)
- **THEN** FT8/JS8 signals appear at correct audio frequencies (1000-3000 Hz)
- **AND** decoded callsigns and messages are valid

#### Scenario: Buffer sizing for decode cycles
- **WHEN** FT8 decode cycle requires 15 seconds of audio at 12 kHz (180,000 samples)
- **THEN** system accumulates sufficient samples from decimated IQ stream
- **AND** triggers demodulation at correct timing boundaries

### Requirement: TX audio to IQ upconversion
The system SHALL convert 12 kHz real modulator output to 48 kHz IQ for Hermes TX.

#### Scenario: FT8/JS8 TX signal generation
- **WHEN** modulator produces real 12 kHz audio samples (FSK tones at 1000-3000 Hz)
- **THEN** system upsamples to 48 kHz using Accelerate/vDSP
- **AND** applies Hilbert transform to produce analytic signal (I + jQ)
- **AND** delivers complex IQ array to HermesTransport for EP2 framing
