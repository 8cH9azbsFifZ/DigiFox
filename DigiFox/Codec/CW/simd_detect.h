/**
 * simd_detect.h — Runtime SIMD capability detection
 */

#ifndef SIMD_DETECT_H
#define SIMD_DETECT_H

typedef enum {
    CW_SIMD_NONE  = 0,
    CW_SIMD_SSE2  = 1,
    CW_SIMD_AVX2  = 2,
    CW_SIMD_NEON  = 3,
} cw_simd_level_t;

/**
 * Detect the best available SIMD instruction set at runtime.
 */
cw_simd_level_t cw_detect_simd(void);

/**
 * Initialize SIMD function pointers (call once at startup).
 * Called automatically by cw_decoder_create() on first use.
 */
void cw_init_simd(void);

#endif /* SIMD_DETECT_H */
