/**
 * iir_filter.h — Butterworth IIR bandpass/lowpass filter (SOS biquad cascade)
 *
 * Designs Butterworth filters using analog prototype → bilinear transform → SOS.
 * Processes audio via Direct Form II Transposed (numerically stable).
 */

#ifndef IIR_FILTER_H
#define IIR_FILTER_H

/* Maximum number of second-order sections (order 10 = 5 sections max) */
#define IIR_MAX_SECTIONS 8

/* Single second-order section (biquad) */
typedef struct {
    float b[3];   /* Numerator: b0, b1, b2 */
    float a[3];   /* Denominator: 1, a1, a2 (a[0] always 1.0) */
    float z[2];   /* State variables (DF-II Transposed) */
} iir_section_t;

/* IIR filter (cascade of biquad sections) */
typedef struct {
    iir_section_t sections[IIR_MAX_SECTIONS];
    int n_sections;
} iir_filter_t;

/**
 * Design a Butterworth lowpass filter.
 *
 * @param f         Output filter
 * @param order     Filter order (1-10, even recommended)
 * @param cutoff_hz Cutoff frequency in Hz
 * @param fs        Sample rate in Hz
 */
void iir_design_lowpass(iir_filter_t *f, int order, float cutoff_hz, float fs);

/**
 * Design a Butterworth bandpass filter.
 *
 * @param f          Output filter
 * @param order      Filter order per side (total order = 2*order)
 * @param low_hz     Lower cutoff in Hz
 * @param high_hz    Upper cutoff in Hz
 * @param fs         Sample rate in Hz
 */
void iir_design_bandpass(iir_filter_t *f, int order,
                         float low_hz, float high_hz, float fs);

/**
 * Process audio samples in-place through the filter.
 *
 * @param f     Filter (state is updated)
 * @param data  Audio samples (modified in-place)
 * @param n     Number of samples
 */
void iir_filter_process(iir_filter_t *f, float *data, int n);

/**
 * Reset filter state to zero (keep coefficients).
 */
void iir_filter_reset(iir_filter_t *f);

#endif /* IIR_FILTER_H */
