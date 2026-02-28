/**
 * iir_filter.c — Butterworth IIR filter design + SOS processing
 *
 * Implements analog prototype → bilinear transform → SOS cascade.
 * Reference: scipy.signal.butter(N, Wn, btype, output='sos')
 */

#include "iir_filter.h"
#include <math.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ------------------------------------------------------------------ */
/* Analog Butterworth prototype poles (unit circle, left half-plane)   */
/* ------------------------------------------------------------------ */

static void butter_analog_poles(int order, float *poles_re, float *poles_im)
{
    for (int k = 0; k < order; k++) {
        float angle = (float)M_PI * (2 * k + order + 1) / (2 * order);
        poles_re[k] = cosf(angle);
        poles_im[k] = sinf(angle);
    }
}

/* ------------------------------------------------------------------ */
/* Bilinear transform: s-plane → z-plane                              */
/*   s = 2*fs * (z-1)/(z+1)  →  z = (1 + s/(2*fs)) / (1 - s/(2*fs)) */
/* ------------------------------------------------------------------ */

static void bilinear_transform(float s_re, float s_im, float fs,
                                float *z_re, float *z_im)
{
    float t = 1.0f / (2.0f * fs);
    /* z = (1 + s*t) / (1 - s*t) */
    float num_re = 1.0f + s_re * t;
    float num_im = s_im * t;
    float den_re = 1.0f - s_re * t;
    float den_im = -s_im * t;

    float den_mag2 = den_re * den_re + den_im * den_im;
    *z_re = (num_re * den_re + num_im * den_im) / den_mag2;
    *z_im = (num_im * den_re - num_re * den_im) / den_mag2;
}

/* ------------------------------------------------------------------ */
/* Build SOS section from a pair of conjugate z-plane poles + zeros    */
/* ------------------------------------------------------------------ */

static void make_sos_from_pole_pair(float pz_re, float pz_im,
                                     float zz_re, float zz_im,
                                     float gain,
                                     iir_section_t *sec)
{
    /* Numerator: (z - z1)(z - z1*) = z^2 - 2*Re(z1)*z + |z1|^2 */
    sec->b[0] = gain;
    sec->b[1] = gain * (-2.0f * zz_re);
    sec->b[2] = gain * (zz_re * zz_re + zz_im * zz_im);

    /* Denominator: (z - p1)(z - p1*) = z^2 - 2*Re(p1)*z + |p1|^2 */
    sec->a[0] = 1.0f;
    sec->a[1] = -2.0f * pz_re;
    sec->a[2] = pz_re * pz_re + pz_im * pz_im;

    sec->z[0] = 0.0f;
    sec->z[1] = 0.0f;
}

static void make_sos_from_real_pole(float pz, float zz, float gain,
                                     iir_section_t *sec)
{
    /* First-order section stored as SOS: b2=0, a2=0 */
    sec->b[0] = gain;
    sec->b[1] = gain * (-zz);
    sec->b[2] = 0.0f;

    sec->a[0] = 1.0f;
    sec->a[1] = -pz;
    sec->a[2] = 0.0f;

    sec->z[0] = 0.0f;
    sec->z[1] = 0.0f;
}

/* ------------------------------------------------------------------ */
/* Lowpass design                                                      */
/* ------------------------------------------------------------------ */

void iir_design_lowpass(iir_filter_t *f, int order, float cutoff_hz, float fs)
{
    memset(f, 0, sizeof(*f));
    if (order < 1 || order > 2 * IIR_MAX_SECTIONS) return;

    /* Pre-warp cutoff for bilinear transform */
    float wn = cutoff_hz / (fs / 2.0f);
    if (wn >= 1.0f) wn = 0.999f;
    if (wn <= 0.0f) wn = 0.001f;
    float warped = 2.0f * fs * tanf((float)M_PI * wn / 2.0f);

    /* Analog prototype poles */
    float ap_re[16], ap_im[16];
    butter_analog_poles(order, ap_re, ap_im);

    /* Scale to cutoff frequency */
    for (int k = 0; k < order; k++) {
        ap_re[k] *= warped;
        ap_im[k] *= warped;
    }

    /* Transform to z-plane and build SOS sections */
    int sec_idx = 0;

    for (int k = 0; k < order / 2; k++) {
        int i = k;
        int j = order - 1 - k;

        /* Take pole pair: poles[i] and poles[j] are conjugate */
        float pz1_re, pz1_im, pz2_re, pz2_im;
        bilinear_transform(ap_re[i], ap_im[i], fs, &pz1_re, &pz1_im);
        bilinear_transform(ap_re[j], ap_im[j], fs, &pz2_re, &pz2_im);

        /* Lowpass zeros at z = -1 (Nyquist) */
        float gain = 1.0f;
        make_sos_from_pole_pair(pz1_re, pz1_im, -1.0f, 0.0f, gain, &f->sections[sec_idx]);
        sec_idx++;
    }

    /* Odd order: one real pole */
    if (order % 2 == 1) {
        int mid = order / 2;
        float pz_re, pz_im;
        bilinear_transform(ap_re[mid], ap_im[mid], fs, &pz_re, &pz_im);
        make_sos_from_real_pole(pz_re, -1.0f, 1.0f, &f->sections[sec_idx]);
        sec_idx++;
    }

    f->n_sections = sec_idx;

    /* Normalize gain: evaluate H(z) at z=1 (DC) and set overall gain = 1 */
    float total_gain = 1.0f;
    for (int s = 0; s < f->n_sections; s++) {
        iir_section_t *sec = &f->sections[s];
        float num_at_dc = sec->b[0] + sec->b[1] + sec->b[2];
        float den_at_dc = sec->a[0] + sec->a[1] + sec->a[2];
        if (fabsf(den_at_dc) > 1e-12f) {
            total_gain *= num_at_dc / den_at_dc;
        }
    }

    /* Apply correction to first section */
    if (fabsf(total_gain) > 1e-12f && f->n_sections > 0) {
        float correction = 1.0f / total_gain;
        f->sections[0].b[0] *= correction;
        f->sections[0].b[1] *= correction;
        f->sections[0].b[2] *= correction;
    }
}

/* ------------------------------------------------------------------ */
/* Bandpass design (lowpass-to-bandpass transform)                     */
/* ------------------------------------------------------------------ */

void iir_design_bandpass(iir_filter_t *f, int order,
                         float low_hz, float high_hz, float fs)
{
    memset(f, 0, sizeof(*f));
    if (order < 1) return;

    /* Normalize to [0, 1] where 1 = Nyquist */
    float nyquist = fs / 2.0f;
    float wn_low  = low_hz / nyquist;
    float wn_high = high_hz / nyquist;
    if (wn_low <= 0.0f)  wn_low = 0.001f;
    if (wn_high >= 1.0f) wn_high = 0.999f;
    if (wn_low >= wn_high) return;

    /* Pre-warp */
    float w_low  = 2.0f * fs * tanf((float)M_PI * wn_low / 2.0f);
    float w_high = 2.0f * fs * tanf((float)M_PI * wn_high / 2.0f);
    float bw = w_high - w_low;
    float w0 = sqrtf(w_low * w_high);

    /* Analog prototype poles */
    float ap_re[16], ap_im[16];
    butter_analog_poles(order, ap_re, ap_im);

    /* Lowpass-to-bandpass: each LP pole p becomes two BP poles:
     *   s = (p*bw/2) ± sqrt((p*bw/2)^2 - w0^2)
     */
    int sec_idx = 0;
    for (int k = 0; k < order; k++) {
        float half_bw_re = ap_re[k] * bw / 2.0f;
        float half_bw_im = ap_im[k] * bw / 2.0f;

        /* (p*bw/2)^2 */
        float sq_re = half_bw_re * half_bw_re - half_bw_im * half_bw_im;
        float sq_im = 2.0f * half_bw_re * half_bw_im;

        /* (p*bw/2)^2 - w0^2 */
        sq_re -= w0 * w0;

        /* Complex sqrt */
        float mag = sqrtf(sq_re * sq_re + sq_im * sq_im);
        float phase = atan2f(sq_im, sq_re);
        float sqrt_mag = sqrtf(mag);
        float sqrt_re = sqrt_mag * cosf(phase / 2.0f);
        float sqrt_im = sqrt_mag * sinf(phase / 2.0f);

        /* Two analog poles from LP→BP transform */
        float s1_re = half_bw_re + sqrt_re;
        float s1_im = half_bw_im + sqrt_im;
        float s2_re = half_bw_re - sqrt_re;
        float s2_im = half_bw_im - sqrt_im;

        /* Bilinear transform each to z-plane */
        float z1_re, z1_im, z2_re, z2_im;
        bilinear_transform(s1_re, s1_im, fs, &z1_re, &z1_im);
        bilinear_transform(s2_re, s2_im, fs, &z2_re, &z2_im);

        /* Build SOS section for each z-plane pole
         * BP zeros: at z=+1 (DC) and z=-1 (Nyquist)
         * So each SOS numerator is z^2 - 1 = (z-1)(z+1) */
        if (sec_idx < IIR_MAX_SECTIONS) {
            iir_section_t *sec = &f->sections[sec_idx];
            sec->b[0] = 1.0f;
            sec->b[1] = 0.0f;
            sec->b[2] = -1.0f;
            sec->a[0] = 1.0f;
            sec->a[1] = -2.0f * z1_re;
            sec->a[2] = z1_re * z1_re + z1_im * z1_im;
            sec->z[0] = 0.0f;
            sec->z[1] = 0.0f;
            sec_idx++;
        }
        if (sec_idx < IIR_MAX_SECTIONS) {
            iir_section_t *sec = &f->sections[sec_idx];
            sec->b[0] = 1.0f;
            sec->b[1] = 0.0f;
            sec->b[2] = -1.0f;
            sec->a[0] = 1.0f;
            sec->a[1] = -2.0f * z2_re;
            sec->a[2] = z2_re * z2_re + z2_im * z2_im;
            sec->z[0] = 0.0f;
            sec->z[1] = 0.0f;
            sec_idx++;
        }
    }
    f->n_sections = sec_idx;

    /* Normalize gain at center frequency */
    float wc = 2.0f * (float)M_PI * (low_hz + high_hz) / 2.0f / fs;
    float cos_wc = cosf(wc);
    float sin_wc = sinf(wc);
    float total_gain_re = 1.0f;
    float total_gain_im = 0.0f;

    for (int s = 0; s < f->n_sections; s++) {
        iir_section_t *sec = &f->sections[s];
        /* Evaluate H(e^jw) = (b0 + b1*e^-jw + b2*e^-2jw) / (1 + a1*e^-jw + a2*e^-2jw) */
        float cos2 = cos_wc * cos_wc - sin_wc * sin_wc;
        float sin2 = 2.0f * sin_wc * cos_wc;

        float nr = sec->b[0] + sec->b[1] * cos_wc + sec->b[2] * cos2;
        float ni = -sec->b[1] * sin_wc - sec->b[2] * sin2;
        float dr = sec->a[0] + sec->a[1] * cos_wc + sec->a[2] * cos2;
        float di = -sec->a[1] * sin_wc - sec->a[2] * sin2;

        float dm2 = dr * dr + di * di;
        if (dm2 < 1e-20f) continue;

        float h_re = (nr * dr + ni * di) / dm2;
        float h_im = (ni * dr - nr * di) / dm2;

        float new_re = total_gain_re * h_re - total_gain_im * h_im;
        float new_im = total_gain_re * h_im + total_gain_im * h_re;
        total_gain_re = new_re;
        total_gain_im = new_im;
    }

    float gain_mag = sqrtf(total_gain_re * total_gain_re +
                           total_gain_im * total_gain_im);
    if (gain_mag > 1e-12f && f->n_sections > 0) {
        float correction = 1.0f / gain_mag;
        f->sections[0].b[0] *= correction;
        f->sections[0].b[1] *= correction;
        f->sections[0].b[2] *= correction;
    }
}

/* ------------------------------------------------------------------ */
/* Process: Direct Form II Transposed                                  */
/* ------------------------------------------------------------------ */

void iir_filter_process(iir_filter_t *f, float *data, int n)
{
    for (int s = 0; s < f->n_sections; s++) {
        iir_section_t *sec = &f->sections[s];
        float b0 = sec->b[0], b1 = sec->b[1], b2 = sec->b[2];
        float a1 = sec->a[1], a2 = sec->a[2];
        float z0 = sec->z[0], z1 = sec->z[1];

        for (int i = 0; i < n; i++) {
            float x = data[i];
            float y = b0 * x + z0;
            z0 = b1 * x - a1 * y + z1;
            z1 = b2 * x - a2 * y;
            data[i] = y;
        }

        sec->z[0] = z0;
        sec->z[1] = z1;
    }
}

void iir_filter_reset(iir_filter_t *f)
{
    for (int s = 0; s < f->n_sections; s++) {
        f->sections[s].z[0] = 0.0f;
        f->sections[s].z[1] = 0.0f;
    }
}
