/**
 * kalman.c — 5-state Kalman filter for CW timing (log-space)
 *
 * Reference: kalman_filter.py::KalmanTimingEstimator
 */

#include "kalman.h"
#include <math.h>
#include <string.h>

#ifndef M_LN2
#define M_LN2 0.693147180559945309f
#endif

void kalman_init(kalman_t *k, int sample_rate, float initial_wpm,
                 float min_wpm, float max_wpm)
{
    memset(k, 0, sizeof(*k));
    k->sample_rate = sample_rate;
    k->min_wpm = min_wpm;
    k->max_wpm = max_wpm;
    k->R = 0.1f;
    k->innovation_gate = M_LN2;  /* log(2.0) ≈ 0.693 */

    /* Process noise (diagonal) */
    for (int i = 0; i < KALMAN_STATES; i++) {
        k->Q[i] = 0.01f;
    }

    kalman_reset(k, initial_wpm);
}

void kalman_reset(kalman_t *k, float initial_wpm)
{
    float dit_s = 1.2f / initial_wpm;
    float dit_samples = dit_s * (float)k->sample_rate;

    k->x[K_DIT]        = logf(dit_samples);
    k->x[K_DAH]        = logf(dit_samples * 3.0f);
    k->x[K_ELEM_SPACE] = logf(dit_samples);
    k->x[K_CHAR_SPACE] = logf(dit_samples * 3.0f);
    k->x[K_WORD_SPACE] = logf(dit_samples * 7.0f);

    /* Initialize P as diagonal 0.1 */
    memset(k->P, 0, sizeof(k->P));
    for (int i = 0; i < KALMAN_STATES; i++) {
        k->P[i][i] = 0.1f;
    }
}

static void apply_bounds(kalman_t *k)
{
    /* WPM bounds on dit */
    float min_dit = (1.2f / k->max_wpm) * (float)k->sample_rate;
    float max_dit = (1.2f / k->min_wpm) * (float)k->sample_rate;
    float log_min = logf(min_dit);
    float log_max = logf(max_dit);

    if (k->x[K_DIT] < log_min) k->x[K_DIT] = log_min;
    if (k->x[K_DIT] > log_max) k->x[K_DIT] = log_max;

    /* Ratio bounds relative to dit (±50% around ITU ratios) */
    float ld = k->x[K_DIT];

    /* dah: 2× to 4× dit */
    float dah_lo = ld + logf(2.0f);
    float dah_hi = ld + logf(4.0f);
    if (k->x[K_DAH] < dah_lo) k->x[K_DAH] = dah_lo;
    if (k->x[K_DAH] > dah_hi) k->x[K_DAH] = dah_hi;

    /* elem_space: 0.5× to 2× dit */
    float es_lo = ld - M_LN2;
    float es_hi = ld + M_LN2;
    if (k->x[K_ELEM_SPACE] < es_lo) k->x[K_ELEM_SPACE] = es_lo;
    if (k->x[K_ELEM_SPACE] > es_hi) k->x[K_ELEM_SPACE] = es_hi;

    /* char_space: 2× to 4× dit */
    float cs_lo = ld + logf(2.0f);
    float cs_hi = ld + logf(4.0f);
    if (k->x[K_CHAR_SPACE] < cs_lo) k->x[K_CHAR_SPACE] = cs_lo;
    if (k->x[K_CHAR_SPACE] > cs_hi) k->x[K_CHAR_SPACE] = cs_hi;

    /* word_space: 5× to 9× dit */
    float ws_lo = ld + logf(5.0f);
    float ws_hi = ld + logf(9.0f);
    if (k->x[K_WORD_SPACE] < ws_lo) k->x[K_WORD_SPACE] = ws_lo;
    if (k->x[K_WORD_SPACE] > ws_hi) k->x[K_WORD_SPACE] = ws_hi;
}

int kalman_update(kalman_t *k, int state_idx, float duration_samples)
{
    if (state_idx < 0 || state_idx >= KALMAN_STATES) return 0;
    if (duration_samples <= 0.0f) return 0;

    float z = logf(duration_samples);
    float innovation = z - k->x[state_idx];

    /* Innovation gating: reject outliers */
    if (fabsf(innovation) > k->innovation_gate) {
        return 0;
    }

    /* Kalman gain: K = P[idx][idx] / (P[idx][idx] + R) */
    int idx = state_idx;
    float S = k->P[idx][idx] + k->R;
    if (S < 1e-10f) S = 1e-10f;

    /* Compute Kalman gain vector (sparse H: only idx-th element = 1) */
    float K[KALMAN_STATES];
    for (int i = 0; i < KALMAN_STATES; i++) {
        K[i] = k->P[i][idx] / S;
    }

    /* State update: x = x + K * innovation */
    for (int i = 0; i < KALMAN_STATES; i++) {
        k->x[i] += K[i] * innovation;
    }

    /* Covariance update: Joseph form P = (I - K*H)*P*(I - K*H)' + K*R*K' */
    float P_new[KALMAN_STATES][KALMAN_STATES];
    for (int i = 0; i < KALMAN_STATES; i++) {
        for (int j = 0; j < KALMAN_STATES; j++) {
            /* (I - K*H) * P */
            float ikh_P = k->P[i][j] - K[i] * k->P[idx][j];
            /* * (I - K*H)' */
            P_new[i][j] = ikh_P - k->P[i][idx] * K[j] + K[i] * k->P[idx][idx] * K[j];
            /* + K*R*K' */
            P_new[i][j] += K[i] * k->R * K[j];
        }
    }

    /* Add process noise (predict step) */
    for (int i = 0; i < KALMAN_STATES; i++) {
        for (int j = 0; j < KALMAN_STATES; j++) {
            k->P[i][j] = P_new[i][j];
        }
        k->P[i][i] += k->Q[i];
    }

    apply_bounds(k);
    return 1;
}

float kalman_get_duration(const kalman_t *k, int state_idx)
{
    if (state_idx < 0 || state_idx >= KALMAN_STATES) return 0.0f;
    return expf(k->x[state_idx]);
}

float kalman_get_threshold(const kalman_t *k, int state_a, int state_b)
{
    /* Geometric mean: sqrt(a * b) = exp((log_a + log_b) / 2) */
    return expf((k->x[state_a] + k->x[state_b]) / 2.0f);
}

float kalman_get_wpm(const kalman_t *k)
{
    float dit_samples = expf(k->x[K_DIT]);
    float dit_s = dit_samples / (float)k->sample_rate;
    if (dit_s <= 0.0f) return 20.0f;
    return 1.2f / dit_s;
}
