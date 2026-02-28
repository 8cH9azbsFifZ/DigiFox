/**
 * cw_decoder.c — CW decoder pipeline: Bandpass → Envelope → Timing → Morse → Output
 *
 * No heap allocation during process() — all state pre-allocated in create().
 */

#include "cw_decoder.h"
#include "iir_filter.h"
#include "envelope.h"
#include "morse_table.h"
#include "timing.h"
#include "output_filter.h"

#include <stdlib.h>
#include <string.h>

/* Maximum pattern length (longest Morse character has 7 elements) */
#define MAX_PATTERN 16

struct cw_decoder_t {
    cw_config_t cfg;

    /* Bandpass filter (optional — applied if bandwidth > 0) */
    iir_filter_t bandpass;
    int use_bandpass;

    /* Envelope detector */
    envelope_t envelope;

    /* Timing classifier */
    timing_t timing;

    /* Pattern decoder state */
    char pattern[MAX_PATTERN];
    int  pattern_len;

    /* Output filter */
    output_filter_t output;
};

/* ------------------------------------------------------------------ */
/* Config init                                                         */
/* ------------------------------------------------------------------ */

void cw_config_init(cw_config_t *cfg)
{
    memset(cfg, 0, sizeof(*cfg));
    cfg->sample_rate      = 48000;
    cfg->center_freq      = 700.0f;
    cfg->bandwidth        = 100.0f;
    cfg->threshold_on     = 0.5f;
    cfg->threshold_off    = 0.4f;
    cfg->timing_mode      = CW_TIMING_KALMAN;
    cfg->envelope_mode    = CW_ENVELOPE_MULTIPASS;
    cfg->initial_wpm      = 20.0f;
    cfg->min_wpm          = 5.0f;
    cfg->max_wpm          = 60.0f;
    cfg->envelope_window_s = 0.005f;
    cfg->min_element_ratio = 0.3f;
    cfg->min_element_s     = 0.010f;
    cfg->use_hmm           = 0;
    cfg->min_word_length   = 2;
    cfg->multipass_passes  = 3;
}

/* ------------------------------------------------------------------ */
/* Create / destroy                                                    */
/* ------------------------------------------------------------------ */

cw_decoder_t *cw_decoder_create(const cw_config_t *cfg)
{
    cw_decoder_t *dec = (cw_decoder_t *)calloc(1, sizeof(cw_decoder_t));
    if (!dec) return NULL;

    dec->cfg = *cfg;

    /* Bandpass filter (only if bandwidth > 0) */
    if (cfg->bandwidth > 0.0f) {
        float low = cfg->center_freq - cfg->bandwidth / 2.0f;
        float high = cfg->center_freq + cfg->bandwidth / 2.0f;
        if (low < 1.0f) low = 1.0f;
        float nyquist = (float)cfg->sample_rate / 2.0f;
        if (high >= nyquist) high = nyquist - 1.0f;
        if (low < high) {
            iir_design_bandpass(&dec->bandpass, 2, low, high, (float)cfg->sample_rate);
            dec->use_bandpass = 1;
        }
    }

    /* Envelope detector */
    envelope_mode_t emode = (cfg->envelope_mode == CW_ENVELOPE_MULTIPASS)
                            ? ENV_MODE_MULTIPASS : ENV_MODE_IIR;
    envelope_init(&dec->envelope, cfg->sample_rate, cfg->envelope_window_s,
                  cfg->threshold_on, cfg->threshold_off,
                  emode, cfg->multipass_passes);

    /* Timing classifier */
    timing_mode_t tmode = (cfg->timing_mode == CW_TIMING_KALMAN)
                          ? TIMING_MODE_KALMAN : TIMING_MODE_EMA;
    timing_init(&dec->timing, tmode, cfg->sample_rate,
                cfg->initial_wpm, cfg->min_wpm, cfg->max_wpm,
                cfg->min_element_ratio, cfg->min_element_s);

    /* Output filter */
    output_filter_init(&dec->output, cfg->min_word_length);

    return dec;
}

void cw_decoder_destroy(cw_decoder_t *dec)
{
    free(dec);
}

/* ------------------------------------------------------------------ */
/* Pattern decoder (inline — no separate file needed)                  */
/* ------------------------------------------------------------------ */

static int pattern_feed(cw_decoder_t *dec, int elem, char *out, int out_len)
{
    if (elem == ELEM_DIT || elem == ELEM_DAH) {
        if (dec->pattern_len < MAX_PATTERN - 1) {
            dec->pattern[dec->pattern_len++] = (char)elem;
        }
        return 0;
    }

    int written = 0;

    if (elem == ELEM_CHAR || elem == ELEM_WORD) {
        if (dec->pattern_len > 0) {
            dec->pattern[dec->pattern_len] = '\0';
            int n = morse_lookup_merged(dec->pattern, out + written, out_len - written);
            written += n;
            dec->pattern_len = 0;
        }
        if (elem == ELEM_WORD && written < out_len) {
            out[written++] = ' ';
        }
    }

    return written;
}

static int pattern_flush(cw_decoder_t *dec, char *out, int out_len)
{
    if (dec->pattern_len <= 0) return 0;
    dec->pattern[dec->pattern_len] = '\0';
    int n = morse_lookup_merged(dec->pattern, out, out_len);
    dec->pattern_len = 0;
    return n;
}

/* ------------------------------------------------------------------ */
/* Process                                                             */
/* ------------------------------------------------------------------ */

int cw_decoder_process(cw_decoder_t *dec, const float *audio, int n,
                       char *out, int out_len)
{
    if (n <= 0 || out_len <= 0) return 0;

    /* Work buffer for audio (to avoid modifying input) */
    /* Process in 4096-sample segments to limit stack usage */
    int total_written = 0;
    int processed = 0;

    while (processed < n && total_written < out_len) {
        int chunk = n - processed;
        if (chunk > 4096) chunk = 4096;

        float work[4096];
        int on_off[4096];

        memcpy(work, audio + processed, chunk * sizeof(float));

        /* Step 1: Bandpass filter */
        if (dec->use_bandpass) {
            iir_filter_process(&dec->bandpass, work, chunk);
        }

        /* Step 2: Envelope detection → on/off */
        envelope_process(&dec->envelope, work, on_off, chunk);

        /* Step 3-4: Timing → Pattern → Output filter, sample by sample */
        for (int i = 0; i < chunk && total_written < out_len; i++) {
            int elem = timing_process_sample(&dec->timing, on_off[i]);
            if (elem != ELEM_NONE) {
                /* Pattern decoder */
                char pat_out[4];
                int pat_n = pattern_feed(dec, elem, pat_out, sizeof(pat_out));

                /* Output filter */
                if (pat_n > 0) {
                    int filt_n = output_filter_feed(&dec->output,
                                                    pat_out, pat_n,
                                                    out + total_written,
                                                    out_len - total_written);
                    total_written += filt_n;
                }
            }
        }

        processed += chunk;
    }

    return total_written;
}

int cw_decoder_finalize(cw_decoder_t *dec, char *out, int out_len)
{
    int written = 0;

    /* Finalize timing (emit pending element) */
    int elem = timing_finalize(&dec->timing);
    if (elem != ELEM_NONE) {
        char pat_out[4];
        int pat_n = pattern_feed(dec, elem, pat_out, sizeof(pat_out));
        if (pat_n > 0) {
            written += output_filter_feed(&dec->output, pat_out, pat_n,
                                          out + written, out_len - written);
        }
    }

    /* Flush pattern decoder */
    {
        char pat_out[4];
        int pat_n = pattern_flush(dec, pat_out, sizeof(pat_out));
        if (pat_n > 0) {
            written += output_filter_feed(&dec->output, pat_out, pat_n,
                                          out + written, out_len - written);
        }
    }

    /* Flush output filter */
    written += output_filter_flush(&dec->output, out + written, out_len - written);

    return written;
}

float cw_decoder_get_wpm(const cw_decoder_t *dec)
{
    return timing_get_wpm(&dec->timing);
}

void cw_decoder_reset(cw_decoder_t *dec)
{
    if (dec->use_bandpass) {
        iir_filter_reset(&dec->bandpass);
    }
    envelope_reset(&dec->envelope);
    timing_reset(&dec->timing, dec->cfg.initial_wpm);
    dec->pattern_len = 0;
    output_filter_reset(&dec->output);
}

/* ------------------------------------------------------------------ */
/* Multi-channel batch API                                             */
/* ------------------------------------------------------------------ */

int cw_decode_multi(const cw_config_t *cfgs, int n_ch,
                    const float **audio, int n,
                    char **out_bufs, int out_len)
{
    /* Simple sequential implementation.
     * SIMD-parallel version in Phase D. */
    for (int ch = 0; ch < n_ch; ch++) {
        cw_decoder_t *dec = cw_decoder_create(&cfgs[ch]);
        if (!dec) return -1;

        int wrote = cw_decoder_process(dec, audio[ch], n, out_bufs[ch], out_len);
        wrote += cw_decoder_finalize(dec, out_bufs[ch] + wrote, out_len - wrote);
        out_bufs[ch][wrote < out_len ? wrote : out_len - 1] = '\0';

        cw_decoder_destroy(dec);
    }
    return 0;
}
