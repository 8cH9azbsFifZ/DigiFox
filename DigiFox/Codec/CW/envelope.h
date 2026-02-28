/**
 * envelope.h — Envelope detector with peak tracking and hysteresis
 *
 * Processing: |audio| → lowpass → peak tracking → hysteresis → on/off
 */

#ifndef ENVELOPE_H
#define ENVELOPE_H

#include "iir_filter.h"
#include "multipass_avg.h"

typedef enum {
    ENV_MODE_IIR       = 0,
    ENV_MODE_MULTIPASS = 1,
} envelope_mode_t;

typedef struct {
    /* Lowpass filter (IIR mode) */
    iir_filter_t lpf;

    /* Multipass average filter */
    multipass_avg_t mpf;

    /* Mode */
    envelope_mode_t mode;

    /* Peak tracking */
    float peak_level;

    /* Hysteresis thresholds (fraction of peak) */
    float threshold_on;
    float threshold_off;

    /* Previous on/off state */
    int prev_state;
} envelope_t;

/**
 * Initialize envelope detector.
 *
 * @param env            Output struct
 * @param sample_rate    Audio sample rate
 * @param window_s       Smoothing window in seconds
 * @param thresh_on      On threshold (fraction of peak, e.g. 0.5)
 * @param thresh_off     Off threshold (fraction of peak, e.g. 0.4)
 * @param mode           ENV_MODE_IIR or ENV_MODE_MULTIPASS
 * @param mp_passes      Number of multipass passes (default 3)
 */
void envelope_init(envelope_t *env, int sample_rate, float window_s,
                   float thresh_on, float thresh_off,
                   envelope_mode_t mode, int mp_passes);

/**
 * Process audio chunk and produce on/off decisions.
 *
 * @param env    Envelope state
 * @param audio  Input audio (not modified)
 * @param on_off Output on/off array (must be same length as audio)
 * @param n      Number of samples
 */
void envelope_process(envelope_t *env, const float *audio, int *on_off, int n);

/**
 * Reset envelope state.
 */
void envelope_reset(envelope_t *env);

#endif /* ENVELOPE_H */
