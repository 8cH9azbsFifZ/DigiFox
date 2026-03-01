#import "ggmorse_c_api.h"
#include "ggmorse.h"

#include <vector>
#include <cstring>

struct ggmorse_wrapper {
    GGMorse * morse;
    std::vector<float> audioBuffer;
    int readOffset;
    float sampleRate;
};

ggmorse_wrapper * ggmorse_wrapper_create(float sampleRate, int samplesPerFrame) {
    auto * inst = new ggmorse_wrapper();
    inst->sampleRate = sampleRate;
    inst->readOffset = 0;

    GGMorse::Parameters params;
    params.sampleRateInp = sampleRate;
    params.sampleRateOut = sampleRate;
    params.samplesPerFrame = samplesPerFrame > 0 ? samplesPerFrame : GGMorse::kDefaultSamplesPerFrame;
    params.sampleFormatInp = GGMORSE_SAMPLE_FORMAT_F32;
    params.sampleFormatOut = GGMORSE_SAMPLE_FORMAT_F32;

    inst->morse = new GGMorse(params);

    // Set decode parameters: auto-detect pitch and speed
    GGMorse::ParametersDecode decParams = GGMorse::getDefaultParametersDecode();
    decParams.frequency_hz = -1.0f;  // auto-detect
    decParams.speed_wpm = -1.0f;     // auto-detect
    decParams.frequencyRangeMin_hz = 200.0f;
    decParams.frequencyRangeMax_hz = 1200.0f;
    decParams.applyFilterHighPass = true;
    decParams.applyFilterLowPass = true;
    inst->morse->setParametersDecode(decParams);

    return inst;
}

void ggmorse_wrapper_destroy(ggmorse_wrapper * inst) {
    if (!inst) return;
    delete inst->morse;
    delete inst;
}

int ggmorse_wrapper_process(ggmorse_wrapper * inst,
                            const float * samples, int nSamples,
                            char * output, int maxOutput) {
    if (!inst || !inst->morse || !samples || nSamples <= 0) return 0;

    // Copy samples into internal buffer
    inst->audioBuffer.assign(samples, samples + nSamples);
    inst->readOffset = 0;

    // Capture pointer for the lambda
    ggmorse_wrapper * ctx = inst;

    // Call decode with callback providing audio data
    inst->morse->decode([ctx](void * data, uint32_t nMaxBytes) -> uint32_t {
        int bytesPerSample = sizeof(float);
        int samplesAvail = (int)ctx->audioBuffer.size() - ctx->readOffset;
        int samplesRequested = nMaxBytes / bytesPerSample;
        int toCopy = std::min(samplesAvail, samplesRequested);
        if (toCopy <= 0) return 0;
        std::memcpy(data, ctx->audioBuffer.data() + ctx->readOffset,
                    toCopy * bytesPerSample);
        ctx->readOffset += toCopy;
        return (uint32_t)(toCopy * bytesPerSample);
    });

    // Get decoded text
    GGMorse::TxRx rxData;
    int n = inst->morse->takeRxData(rxData);
    if (n <= 0 || maxOutput <= 0) return 0;

    int outLen = std::min(n, maxOutput - 1);
    for (int i = 0; i < outLen; i++) {
        output[i] = (char)rxData[i];
    }
    output[outLen] = '\0';
    return outLen;
}

float ggmorse_wrapper_get_pitch(ggmorse_wrapper * inst) {
    if (!inst || !inst->morse) return 0;
    return inst->morse->getStatistics().estimatedPitch_Hz;
}

float ggmorse_wrapper_get_speed(ggmorse_wrapper * inst) {
    if (!inst || !inst->morse) return 0;
    return inst->morse->getStatistics().estimatedSpeed_wpm;
}

void ggmorse_wrapper_reset(ggmorse_wrapper * inst) {
    if (!inst || !inst->morse) return;
    // Recreate to reset all state
    float sr = inst->sampleRate;
    int spf = inst->morse->getSamplesPerFrame();
    delete inst->morse;

    GGMorse::Parameters params;
    params.sampleRateInp = sr;
    params.sampleRateOut = sr;
    params.samplesPerFrame = spf;
    params.sampleFormatInp = GGMORSE_SAMPLE_FORMAT_F32;
    params.sampleFormatOut = GGMORSE_SAMPLE_FORMAT_F32;
    inst->morse = new GGMorse(params);

    GGMorse::ParametersDecode decParams = GGMorse::getDefaultParametersDecode();
    decParams.frequency_hz = -1.0f;
    decParams.speed_wpm = -1.0f;
    decParams.frequencyRangeMin_hz = 200.0f;
    decParams.frequencyRangeMax_hz = 1200.0f;
    decParams.applyFilterHighPass = true;
    decParams.applyFilterLowPass = true;
    inst->morse->setParametersDecode(decParams);

    inst->audioBuffer.clear();
    inst->readOffset = 0;
}
