#ifndef GGMORSE_C_API_H
#define GGMORSE_C_API_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ggmorse_wrapper ggmorse_wrapper;

/// Create a ggmorse decoder instance.
/// @param sampleRate Input audio sample rate (e.g. 12000, 48000)
/// @param samplesPerFrame Samples per processing frame (default 128)
ggmorse_wrapper * ggmorse_wrapper_create(float sampleRate, int samplesPerFrame);

/// Destroy a ggmorse decoder instance.
void ggmorse_wrapper_destroy(ggmorse_wrapper * inst);

/// Feed audio samples and decode.
/// @param samples Float audio samples in [-1, 1]
/// @param nSamples Number of samples
/// @param output Output buffer for decoded text
/// @param maxOutput Max output buffer size
/// @return Number of decoded characters (0 if none)
int ggmorse_wrapper_process(ggmorse_wrapper * inst,
                            const float * samples, int nSamples,
                            char * output, int maxOutput);

/// Get estimated pitch frequency in Hz.
float ggmorse_wrapper_get_pitch(ggmorse_wrapper * inst);

/// Get estimated speed in WPM.
float ggmorse_wrapper_get_speed(ggmorse_wrapper * inst);

/// Reset decoder state.
void ggmorse_wrapper_reset(ggmorse_wrapper * inst);

#ifdef __cplusplus
}
#endif

#endif /* GGMORSE_C_API_H */
