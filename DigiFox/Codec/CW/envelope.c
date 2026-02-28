/**
 * envelope.c — Envelope detector with peak tracking and hysteresis
 */

#include "envelope.h"
#include <math.h>
#include <string.h>

void envelope_init(envelope_t *env, int sample_rate, float window_s,
                   float thresh_on, float thresh_off,
                   envelope_mode_t mode, int mp_passes)
{
    memset(env, 0, sizeof(*env));
    env->threshold_on = thresh_on;
    env->threshold_off = thresh_off;
    env->peak_level = 0.0f;
    env->prev_state = 0;
    env->mode = mode;

    if (mode == ENV_MODE_MULTIPASS) {
        /* Calculate window size matching Python:
         * cutoff = 1.0 / (2.0 * window_s)
         * window = int(sample_rate / (cutoff * pi * sqrt(n_passes)))
         */
        float cutoff = 1.0f / (2.0f * window_s);
        float window_f = (float)sample_rate / (cutoff * (float)M_PI * sqrtf((float)mp_passes));
        int window = (int)window_f;
        if (window < 5) window = 5;
        if (window % 2 == 0) window++;
        multipass_init(&env->mpf, mp_passes, window);
    } else {
        /* IIR lowpass design */
        float cutoff_hz = 1.0f / (2.0f * window_s);
        iir_design_lowpass(&env->lpf, 2, cutoff_hz, (float)sample_rate);
    }
}

void envelope_process(envelope_t *env, const float *audio, int *on_off, int n)
{
    /* Step 1: Rectify — work on a temporary buffer to avoid modifying input.
     * For large chunks we process in segments to limit stack usage. */
    float tmp[4096];
    int processed = 0;

    while (processed < n) {
        int chunk = n - processed;
        if (chunk > 4096) chunk = 4096;

        /* Rectify */
        for (int i = 0; i < chunk; i++) {
            tmp[i] = fabsf(audio[processed + i]);
        }

        /* Step 2: Lowpass filter */
        if (env->mode == ENV_MODE_MULTIPASS) {
            multipass_process(&env->mpf, tmp, chunk);
        } else {
            iir_filter_process(&env->lpf, tmp, chunk);
        }

        /* Step 3: Peak tracking */
        float chunk_peak = 0.0f;
        for (int i = 0; i < chunk; i++) {
            if (tmp[i] > chunk_peak) chunk_peak = tmp[i];
        }

        if (chunk_peak > env->peak_level) {
            env->peak_level = chunk_peak;
        } else {
            env->peak_level = 0.995f * env->peak_level + 0.005f * chunk_peak;
        }

        /* Step 4: Hysteresis thresholding */
        float on_thr  = env->peak_level * env->threshold_on;
        float off_thr = env->peak_level * env->threshold_off;
        if (on_thr < 1e-10f) on_thr = 1e-10f;
        if (off_thr < 1e-10f) off_thr = 1e-10f;

        int state = env->prev_state;
        for (int i = 0; i < chunk; i++) {
            if (state) {
                state = (tmp[i] >= off_thr) ? 1 : 0;
            } else {
                state = (tmp[i] >= on_thr) ? 1 : 0;
            }
            on_off[processed + i] = state;
        }
        env->prev_state = state;

        processed += chunk;
    }
}

void envelope_reset(envelope_t *env)
{
    env->peak_level = 0.0f;
    env->prev_state = 0;
    if (env->mode == ENV_MODE_MULTIPASS) {
        multipass_reset(&env->mpf);
    } else {
        iir_filter_reset(&env->lpf);
    }
}
