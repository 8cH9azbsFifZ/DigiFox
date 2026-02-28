/**
 * iir_filter_neon.c — NEON multi-channel IIR filter
 *
 * Processes up to 4 channels in parallel using 128-bit NEON registers.
 * Each lane = one channel, same biquad coefficients across all channels.
 *
 * Only compiled on AArch64 (NEON always available).
 */

#if defined(__aarch64__) || defined(_M_ARM64)

#include "iir_filter.h"
#include <arm_neon.h>

/**
 * Process N channels (up to 4) through the same IIR filter in parallel.
 */
void iir_filter_process_multi_neon(const iir_filter_t *f,
                                    float **data, int n_ch, int n_samples,
                                    float *states)
{
    if (n_ch <= 0 || n_ch > 4) return;

    for (int s = 0; s < f->n_sections; s++) {
        const iir_section_t *sec = &f->sections[s];

        float32x4_t vb0 = vdupq_n_f32(sec->b[0]);
        float32x4_t vb1 = vdupq_n_f32(sec->b[1]);
        float32x4_t vb2 = vdupq_n_f32(sec->b[2]);
        float32x4_t va1 = vdupq_n_f32(sec->a[1]);
        float32x4_t va2 = vdupq_n_f32(sec->a[2]);

        /* Load per-channel states */
        float z0_arr[4] = {0}, z1_arr[4] = {0};
        for (int ch = 0; ch < n_ch; ch++) {
            z0_arr[ch] = states[(s * n_ch + ch) * 2 + 0];
            z1_arr[ch] = states[(s * n_ch + ch) * 2 + 1];
        }
        float32x4_t vz0 = vld1q_f32(z0_arr);
        float32x4_t vz1 = vld1q_f32(z1_arr);

        for (int i = 0; i < n_samples; i++) {
            /* Gather input */
            float x_arr[4] = {0};
            for (int ch = 0; ch < n_ch; ch++) {
                x_arr[ch] = data[ch][i];
            }
            float32x4_t vx = vld1q_f32(x_arr);

            /* y = b0*x + z0 */
            float32x4_t vy = vfmaq_f32(vz0, vb0, vx);

            /* z0 = b1*x - a1*y + z1 */
            vz0 = vfmaq_f32(vz1, vb1, vx);
            vz0 = vfmsq_f32(vz0, va1, vy);

            /* z1 = b2*x - a2*y */
            vz1 = vmulq_f32(vb2, vx);
            vz1 = vfmsq_f32(vz1, va2, vy);

            /* Scatter output */
            float y_arr[4];
            vst1q_f32(y_arr, vy);
            for (int ch = 0; ch < n_ch; ch++) {
                data[ch][i] = y_arr[ch];
            }
        }

        /* Store states */
        vst1q_f32(z0_arr, vz0);
        vst1q_f32(z1_arr, vz1);
        for (int ch = 0; ch < n_ch; ch++) {
            states[(s * n_ch + ch) * 2 + 0] = z0_arr[ch];
            states[(s * n_ch + ch) * 2 + 1] = z1_arr[ch];
        }
    }
}

#endif /* __aarch64__ */
