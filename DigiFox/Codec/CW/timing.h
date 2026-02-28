/**
 * timing.h — Element classification: mark/space durations → Morse elements
 *
 * Tracks on/off transitions, classifies durations as dit/dah/char_gap/word_gap.
 * Supports Kalman and EMA timing modes.
 */

#ifndef TIMING_H
#define TIMING_H

#include "kalman.h"

#define TIMING_KALMAN_WARMUP 8

typedef enum {
    TIMING_MODE_EMA    = 0,
    TIMING_MODE_KALMAN = 1,
} timing_mode_t;

/* Element codes returned by timing_process_sample() */
#define ELEM_NONE 0    /* No output (accumulating) */
#define ELEM_DIT  '.'  /* Dit */
#define ELEM_DAH  '-'  /* Dah */
#define ELEM_CHAR 'C'  /* Character gap */
#define ELEM_WORD 'W'  /* Word gap */

typedef struct {
    timing_mode_t mode;
    int sample_rate;

    /* Kalman filter (Kalman mode) */
    kalman_t kalman;

    /* EMA state */
    float avg_dit;            /* Average dit duration in samples */
    float ema_alpha;          /* Smoothing factor (default 0.1) */

    /* EMA thresholds (multiples of dit) */
    float dit_dah_threshold;  /* 2.0 */
    float char_pause_ratio;   /* 2.5 */
    float word_pause_ratio;   /* 6.0 */

    /* Noise rejection */
    float min_element_ratio;  /* 0.3 */
    int   min_element_abs;    /* Absolute floor in samples */

    /* Running state */
    int on_dur;               /* Current on-duration in samples */
    int off_dur;              /* Current off-duration in samples */
    int prev_on;              /* Previous state */
    int seen_signal;          /* True after first element */
    int element_count;        /* Element counter for warmup */
} timing_t;

/**
 * Initialize timing classifier.
 */
void timing_init(timing_t *t, timing_mode_t mode, int sample_rate,
                 float initial_wpm, float min_wpm, float max_wpm,
                 float min_element_ratio, float min_element_s);

/**
 * Process a single on/off sample.
 * Returns element code (ELEM_DIT, ELEM_DAH, ELEM_CHAR, ELEM_WORD, or ELEM_NONE).
 */
int timing_process_sample(timing_t *t, int on);

/**
 * Finalize: emit pending element (if any).
 */
int timing_finalize(timing_t *t);

/**
 * Get current WPM estimate.
 */
float timing_get_wpm(const timing_t *t);

/**
 * Reset timing state.
 */
void timing_reset(timing_t *t, float initial_wpm);

#endif /* TIMING_H */
