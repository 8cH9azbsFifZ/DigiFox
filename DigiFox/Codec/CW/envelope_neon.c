/**
 * envelope_neon.c — NEON vectorized envelope operations
 *
 * Vectorizes rectification (fabsf) for multi-channel batch processing.
 */

#if defined(__aarch64__) || defined(_M_ARM64)

#include <arm_neon.h>

/**
 * Rectify N samples in-place: data[i] = fabsf(data[i])
 * Processes 4 floats at a time.
 */
void envelope_rectify_neon(float *data, int n)
{
    int i = 0;
    for (; i + 3 < n; i += 4) {
        float32x4_t v = vld1q_f32(data + i);
        v = vabsq_f32(v);
        vst1q_f32(data + i, v);
    }
    /* Scalar remainder */
    for (; i < n; i++) {
        if (data[i] < 0.0f) data[i] = -data[i];
    }
}

#endif /* __aarch64__ */
