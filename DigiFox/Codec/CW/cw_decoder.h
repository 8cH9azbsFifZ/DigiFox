/**
 * cw_decoder.h — Public C API for CW Decoder Core
 *
 * Single-header interface for consumers. Provides single-channel
 * and multi-channel batch decoding of CW (Morse code) audio.
 *
 * Usage:
 *   cw_config_t cfg;
 *   cw_config_init(&cfg);
 *   cfg.center_freq = 700.0f;
 *
 *   cw_decoder_t *dec = cw_decoder_create(&cfg);
 *   char out[256];
 *   int n = cw_decoder_process(dec, audio, num_samples, out, sizeof(out));
 *   out[n] = '\0';
 *   printf("Decoded: %s\n", out);
 *   cw_decoder_destroy(dec);
 */

#ifndef CW_DECODER_H
#define CW_DECODER_H

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque decoder handle */
typedef struct cw_decoder_t cw_decoder_t;

/* Timing mode selection */
typedef enum {
    CW_TIMING_EMA    = 0,   /* Exponential moving average (simple) */
    CW_TIMING_KALMAN = 1,   /* 5-state Kalman in log-space (default) */
} cw_timing_mode_t;

/* Envelope mode selection */
typedef enum {
    CW_ENVELOPE_IIR       = 0,   /* Butterworth lowpass */
    CW_ENVELOPE_MULTIPASS = 1,   /* Cascaded moving average (default) */
} cw_envelope_mode_t;

/* Configuration struct — all fields have sensible defaults via cw_config_init() */
typedef struct cw_config_t {
    int   sample_rate;       /* Audio sample rate in Hz (default: 48000) */
    float center_freq;       /* CW tone frequency in Hz (default: 700.0) */
    float bandwidth;         /* Bandpass filter width in Hz (default: 100.0) */

    float threshold_on;      /* Hysteresis on threshold (fraction of peak, default: 0.5) */
    float threshold_off;     /* Hysteresis off threshold (fraction of peak, default: 0.4) */

    cw_timing_mode_t   timing_mode;    /* Default: CW_TIMING_KALMAN */
    cw_envelope_mode_t envelope_mode;  /* Default: CW_ENVELOPE_MULTIPASS */

    float initial_wpm;       /* Initial speed estimate (default: 20.0) */
    float min_wpm;           /* Minimum WPM bound (default: 5.0) */
    float max_wpm;           /* Maximum WPM bound (default: 60.0) */

    float envelope_window_s; /* Envelope smoothing window in seconds (default: 0.005) */
    float min_element_ratio; /* Noise reject: min element as fraction of dit (default: 0.3) */
    float min_element_s;     /* Noise reject: absolute floor in seconds (default: 0.010) */

    int   use_hmm;           /* Enable duration HMM (0=off, default: 0) */
    int   min_word_length;   /* Output filter: minimum word length (default: 2) */

    int   multipass_passes;  /* Number of moving-average passes (default: 3) */
} cw_config_t;

/**
 * Initialize config with default values.
 * Always call this before modifying individual fields.
 */
void cw_config_init(cw_config_t *cfg);

/**
 * Create a decoder instance.
 * Returns NULL on allocation failure.
 */
cw_decoder_t *cw_decoder_create(const cw_config_t *cfg);

/**
 * Process an audio chunk and decode CW.
 *
 * @param dec      Decoder handle
 * @param audio    Audio samples (mono, float, range [-1, 1])
 * @param n        Number of samples
 * @param out      Output buffer for decoded ASCII text
 * @param out_len  Size of output buffer
 * @return         Number of characters written to out (not null-terminated)
 */
int cw_decoder_process(cw_decoder_t *dec, const float *audio, int n,
                       char *out, int out_len);

/**
 * Finalize decoding — flush remaining buffered text.
 * Call when no more audio data is expected.
 *
 * @return Number of characters written to out
 */
int cw_decoder_finalize(cw_decoder_t *dec, char *out, int out_len);

/**
 * Get current estimated WPM.
 */
float cw_decoder_get_wpm(const cw_decoder_t *dec);

/**
 * Reset decoder state for reuse (same config).
 */
void cw_decoder_reset(cw_decoder_t *dec);

/**
 * Destroy decoder and free all resources.
 */
void cw_decoder_destroy(cw_decoder_t *dec);

/**
 * Multi-channel batch API.
 * Decodes N channels in parallel (same audio length per channel).
 *
 * @param cfgs      Array of N configs (one per channel)
 * @param n_ch      Number of channels
 * @param audio     Array of N float pointers (one per channel)
 * @param n         Number of samples per channel
 * @param out_bufs  Array of N char pointers (pre-allocated output buffers)
 * @param out_len   Size of each output buffer
 * @return          0 on success, -1 on error
 */
int cw_decode_multi(const cw_config_t *cfgs, int n_ch,
                    const float **audio, int n,
                    char **out_bufs, int out_len);

#ifdef __cplusplus
}
#endif

#endif /* CW_DECODER_H */
