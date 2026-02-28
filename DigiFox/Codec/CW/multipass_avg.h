/**
 * multipass_avg.h — Cascaded moving-average filter (FIR, zero-phase-like)
 *
 * N passes of M-point moving average approximates a Gaussian filter.
 * Ring buffer per pass to handle chunk boundaries.
 */

#ifndef MULTIPASS_AVG_H
#define MULTIPASS_AVG_H

#define MULTIPASS_MAX_PASSES  8
#define MULTIPASS_MAX_WINDOW  256

typedef struct {
    int n_passes;
    int window_size;

    /* Per-pass ring buffer (stores last window_size-1 samples) */
    float buffers[MULTIPASS_MAX_PASSES][MULTIPASS_MAX_WINDOW];
    int   buf_len[MULTIPASS_MAX_PASSES];  /* How many valid samples in buffer */

    /* Running sum per pass (for O(1) moving average) */
    float running_sum[MULTIPASS_MAX_PASSES];
} multipass_avg_t;

/**
 * Initialize multipass average filter.
 */
void multipass_init(multipass_avg_t *mp, int n_passes, int window_size);

/**
 * Process samples in-place through cascaded moving average.
 */
void multipass_process(multipass_avg_t *mp, float *data, int n);

/**
 * Reset filter state.
 */
void multipass_reset(multipass_avg_t *mp);

#endif /* MULTIPASS_AVG_H */
