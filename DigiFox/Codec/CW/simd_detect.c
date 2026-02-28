/**
 * simd_detect.c — Runtime SIMD detection
 *
 * x86_64: CPUID to detect SSE2/AVX2
 * AArch64: NEON always available (compile-time)
 */

#include "simd_detect.h"
#include <stddef.h>

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#define CW_ARCH_X86 1
#ifdef _MSC_VER
#include <intrin.h>
#else
#include <cpuid.h>
#endif
#endif

#if defined(__aarch64__) || defined(_M_ARM64)
#define CW_ARCH_ARM64 1
#endif

cw_simd_level_t cw_detect_simd(void)
{
#if defined(CW_ARCH_ARM64)
    /* NEON is always available on AArch64 */
    return CW_SIMD_NEON;

#elif defined(CW_ARCH_X86)
    unsigned int eax, ebx, ecx, edx;

    /* Check for AVX2: CPUID leaf 7, EBX bit 5 */
#ifdef _MSC_VER
    int cpuinfo[4];
    __cpuid(cpuinfo, 0);
    if (cpuinfo[0] >= 7) {
        __cpuidex(cpuinfo, 7, 0);
        if (cpuinfo[1] & (1 << 5)) return CW_SIMD_AVX2;
    }
    /* SSE2 always available on x86_64 */
    return CW_SIMD_SSE2;
#else
    if (__get_cpuid_max(0, NULL) >= 7) {
        __cpuid_count(7, 0, eax, ebx, ecx, edx);
        if (ebx & (1 << 5)) return CW_SIMD_AVX2;
    }
    return CW_SIMD_SSE2;
#endif

#else
    return CW_SIMD_NONE;
#endif
}

/* Function pointer dispatch — filled by cw_init_simd() */
static int _simd_initialized = 0;

void cw_init_simd(void)
{
    if (_simd_initialized) return;
    _simd_initialized = 1;

    /* Currently the scalar code is used for all paths.
     * SIMD-specific function pointers will be set here
     * when AVX2/NEON variants are compiled. */
    (void)cw_detect_simd();  /* Detect but don't dispatch yet */
}
