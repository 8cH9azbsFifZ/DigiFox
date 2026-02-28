/**
 * timing.c — Element classification from mark/space durations
 *
 * Reference: deep_decoder.py::_TimingClassifier
 */

#include "timing.h"
#include <math.h>
#include <string.h>

void timing_init(timing_t *t, timing_mode_t mode, int sample_rate,
                 float initial_wpm, float min_wpm, float max_wpm,
                 float min_element_ratio, float min_element_s)
{
    memset(t, 0, sizeof(*t));
    t->mode = mode;
    t->sample_rate = sample_rate;
    t->min_element_ratio = min_element_ratio;
    t->min_element_abs = (int)(min_element_s * (float)sample_rate);

    /* EMA defaults */
    t->ema_alpha = 0.1f;
    t->dit_dah_threshold = 2.0f;
    t->char_pause_ratio = 2.5f;
    t->word_pause_ratio = 6.0f;

    float dit_s = 1.2f / initial_wpm;
    t->avg_dit = dit_s * (float)sample_rate;

    if (mode == TIMING_MODE_KALMAN) {
        kalman_init(&t->kalman, sample_rate, initial_wpm, min_wpm, max_wpm);
    }
}

/* Classify a signal (mark) duration */
static int classify_signal_kalman(timing_t *t, int dur)
{
    float avg_dit = kalman_get_duration(&t->kalman, K_DIT);
    int min_dur = (int)(avg_dit * t->min_element_ratio);
    if (min_dur < t->min_element_abs) min_dur = t->min_element_abs;

    if (dur < min_dur) return ELEM_NONE;  /* Noise */

    t->element_count++;
    int warm = (t->element_count > TIMING_KALMAN_WARMUP);

    float thresh = kalman_get_threshold(&t->kalman, K_DIT, K_DAH);

    if ((float)dur < thresh) {
        if (warm) kalman_update(&t->kalman, K_DIT, (float)dur);
        return ELEM_DIT;
    } else {
        if (warm) kalman_update(&t->kalman, K_DAH, (float)dur);
        return ELEM_DAH;
    }
}

static int classify_signal_ema(timing_t *t, int dur)
{
    int min_dur = (int)(t->avg_dit * t->min_element_ratio);
    if (min_dur < t->min_element_abs) min_dur = t->min_element_abs;

    if (dur < min_dur) return ELEM_NONE;

    float thresh = t->avg_dit * t->dit_dah_threshold;
    if ((float)dur < thresh) {
        /* Update dit estimate (EMA) */
        t->avg_dit = (1.0f - t->ema_alpha) * t->avg_dit + t->ema_alpha * (float)dur;
        return ELEM_DIT;
    }
    return ELEM_DAH;
}

/* Classify a gap (space) duration */
static int classify_gap_kalman(timing_t *t, int dur)
{
    int warm = (t->element_count > TIMING_KALMAN_WARMUP);

    float word_thresh = kalman_get_threshold(&t->kalman, K_CHAR_SPACE, K_WORD_SPACE);
    float char_thresh = kalman_get_threshold(&t->kalman, K_ELEM_SPACE, K_CHAR_SPACE);

    if ((float)dur >= word_thresh) {
        if (warm) kalman_update(&t->kalman, K_WORD_SPACE, (float)dur);
        return ELEM_WORD;
    } else if ((float)dur >= char_thresh) {
        if (warm) kalman_update(&t->kalman, K_CHAR_SPACE, (float)dur);
        return ELEM_CHAR;
    } else {
        if (warm) kalman_update(&t->kalman, K_ELEM_SPACE, (float)dur);
        return ELEM_NONE;
    }
}

static int classify_gap_ema(timing_t *t, int dur)
{
    float word_thresh = t->avg_dit * t->word_pause_ratio;
    float char_thresh = t->avg_dit * t->char_pause_ratio;

    if ((float)dur >= word_thresh) return ELEM_WORD;
    if ((float)dur >= char_thresh) return ELEM_CHAR;
    return ELEM_NONE;
}

int timing_process_sample(timing_t *t, int on)
{
    int result = ELEM_NONE;

    if (on) {
        t->on_dur++;
    } else {
        t->off_dur++;
    }

    /* ON → OFF transition: classify signal */
    if (t->prev_on && !on) {
        if (t->mode == TIMING_MODE_KALMAN) {
            result = classify_signal_kalman(t, t->on_dur);
        } else {
            result = classify_signal_ema(t, t->on_dur);
        }
        t->on_dur = 0;
        t->seen_signal = 1;
    }

    /* OFF → ON transition: classify gap */
    if (!t->prev_on && on) {
        if (t->seen_signal) {
            int gap_result;
            if (t->mode == TIMING_MODE_KALMAN) {
                gap_result = classify_gap_kalman(t, t->off_dur);
            } else {
                gap_result = classify_gap_ema(t, t->off_dur);
            }
            /* Gap result may override pending output */
            if (gap_result != ELEM_NONE) {
                /* Return the gap result. The signal result was already returned
                 * on the ON→OFF transition. */
                result = gap_result;
            }
        }
        t->off_dur = 0;
    }

    t->prev_on = on;
    return result;
}

int timing_finalize(timing_t *t)
{
    /* If we have a pending on-duration, classify it */
    if (t->on_dur > 0 && t->seen_signal) {
        int result;
        if (t->mode == TIMING_MODE_KALMAN) {
            result = classify_signal_kalman(t, t->on_dur);
        } else {
            result = classify_signal_ema(t, t->on_dur);
        }
        t->on_dur = 0;
        return result;
    }
    return ELEM_NONE;
}

float timing_get_wpm(const timing_t *t)
{
    if (t->mode == TIMING_MODE_KALMAN) {
        return kalman_get_wpm(&t->kalman);
    }
    /* EMA: derive WPM from avg_dit */
    float dit_s = t->avg_dit / (float)t->sample_rate;
    if (dit_s <= 0.0f) return 20.0f;
    return 1.2f / dit_s;
}

void timing_reset(timing_t *t, float initial_wpm)
{
    float dit_s = 1.2f / initial_wpm;
    t->avg_dit = dit_s * (float)t->sample_rate;
    t->on_dur = 0;
    t->off_dur = 0;
    t->prev_on = 0;
    t->seen_signal = 0;
    t->element_count = 0;

    if (t->mode == TIMING_MODE_KALMAN) {
        kalman_reset(&t->kalman, initial_wpm);
    }
}
