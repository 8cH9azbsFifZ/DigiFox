/**
 * kalman.h — 5-state Kalman filter for CW timing estimation (log-space)
 *
 * States: [log(dit), log(dah), log(elem_space), log(char_space), log(word_space)]
 * All in sample-count units (log-space for multiplicative errors).
 */

#ifndef KALMAN_H
#define KALMAN_H

#define KALMAN_STATES 5

/* State indices */
#define K_DIT        0
#define K_DAH        1
#define K_ELEM_SPACE 2
#define K_CHAR_SPACE 3
#define K_WORD_SPACE 4

typedef struct {
    float x[KALMAN_STATES];                    /* State vector (log-space) */
    float P[KALMAN_STATES][KALMAN_STATES];     /* Covariance */
    float Q[KALMAN_STATES];                    /* Process noise (diagonal) */
    float R;                                   /* Measurement noise */
    float innovation_gate;                     /* Log-space gate (default: log(2)) */

    int   sample_rate;
    float min_wpm;
    float max_wpm;
} kalman_t;

/**
 * Initialize Kalman filter from initial WPM estimate.
 */
void kalman_init(kalman_t *k, int sample_rate, float initial_wpm,
                 float min_wpm, float max_wpm);

/**
 * Update a specific state with a measurement (duration in samples).
 * Returns 1 if accepted, 0 if rejected (outside innovation gate).
 */
int kalman_update(kalman_t *k, int state_idx, float duration_samples);

/**
 * Get current duration estimate for a state (in samples).
 */
float kalman_get_duration(const kalman_t *k, int state_idx);

/**
 * Get geometric mean threshold between two adjacent states.
 * Used for classification: sqrt(state_a * state_b)
 */
float kalman_get_threshold(const kalman_t *k, int state_a, int state_b);

/**
 * Get current WPM estimate (derived from dit duration).
 */
float kalman_get_wpm(const kalman_t *k);

/**
 * Reset to initial state.
 */
void kalman_reset(kalman_t *k, float initial_wpm);

#endif /* KALMAN_H */
