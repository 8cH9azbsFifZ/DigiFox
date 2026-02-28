/**
 * multipass_avg.c — Cascaded moving-average filter
 */

#include "multipass_avg.h"
#include <string.h>

void multipass_init(multipass_avg_t *mp, int n_passes, int window_size)
{
    memset(mp, 0, sizeof(*mp));
    if (n_passes < 1) n_passes = 1;
    if (n_passes > MULTIPASS_MAX_PASSES) n_passes = MULTIPASS_MAX_PASSES;
    if (window_size < 3) window_size = 3;
    if (window_size > MULTIPASS_MAX_WINDOW) window_size = MULTIPASS_MAX_WINDOW;
    if (window_size % 2 == 0) window_size++;  /* Must be odd */

    mp->n_passes = n_passes;
    mp->window_size = window_size;
}

void multipass_process(multipass_avg_t *mp, float *data, int n)
{
    int w = mp->window_size;
    float inv_w = 1.0f / (float)w;

    for (int pass = 0; pass < mp->n_passes; pass++) {
        float *buf = mp->buffers[pass];
        int buf_n = mp->buf_len[pass];

        /* Process each sample as a moving average using a sliding window.
         * We prepend the buffer from the previous chunk to handle boundaries. */

        /* Running sum approach: maintain sum of last w samples */
        float sum = mp->running_sum[pass];

        /* If buffer is not yet full, we need to initialize the sum */
        if (buf_n == 0 && n > 0) {
            /* Cold start: fill with first sample */
            sum = data[0] * (float)(w - 1);
        }

        for (int i = 0; i < n; i++) {
            /* Add new sample to window */
            sum += data[i];

            /* Remove oldest sample from window */
            int oldest_idx = i - w;
            if (oldest_idx >= 0) {
                sum -= data[oldest_idx];
            } else {
                /* Oldest is in the buffer from previous chunk */
                int buf_idx = buf_n + oldest_idx;
                if (buf_idx >= 0 && buf_idx < buf_n) {
                    sum -= buf[buf_idx];
                } else {
                    /* Buffer not long enough — use first available value */
                    sum -= data[0];
                }
            }

            data[i] = sum * inv_w;
        }

        /* Save last (w-1) samples as buffer for next chunk */
        int save_n = w - 1;
        if (save_n > n) save_n = n;
        if (save_n > MULTIPASS_MAX_WINDOW) save_n = MULTIPASS_MAX_WINDOW;

        if (n >= w - 1) {
            /* Copy from data */
            for (int j = 0; j < save_n; j++) {
                buf[j] = data[n - save_n + j];
            }
            mp->buf_len[pass] = save_n;
        } else {
            /* Shift old buffer and append new data */
            int keep = buf_n - n;
            if (keep < 0) keep = 0;
            if (keep > 0) {
                for (int j = 0; j < keep; j++) {
                    buf[j] = buf[buf_n - keep + j];
                }
            }
            for (int j = 0; j < n && keep + j < MULTIPASS_MAX_WINDOW; j++) {
                buf[keep + j] = data[j];
            }
            mp->buf_len[pass] = keep + n;
            if (mp->buf_len[pass] > save_n) mp->buf_len[pass] = save_n;
        }

        mp->running_sum[pass] = sum;
    }
}

void multipass_reset(multipass_avg_t *mp)
{
    for (int i = 0; i < mp->n_passes; i++) {
        memset(mp->buffers[i], 0, sizeof(mp->buffers[i]));
        mp->buf_len[i] = 0;
        mp->running_sum[i] = 0.0f;
    }
}
