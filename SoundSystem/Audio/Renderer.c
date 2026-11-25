#include "Renderer.h"
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct SSRenderer {
    _Atomic float targetGain;
    float currentGain; // audio thread only
};

SSRenderer *SSRendererCreate(float initialGain) {
    SSRenderer *r = calloc(1, sizeof(SSRenderer));
    atomic_init(&r->targetGain, initialGain);
    r->currentGain = initialGain;
    return r;
}

void SSRendererDestroy(SSRenderer *r) { free(r); }

void SSRendererSetGain(SSRenderer *r, float gain) {
    atomic_store_explicit(&r->targetGain, gain, memory_order_relaxed);
}

OSStatus SSRendererIOProc(AudioObjectID device, const AudioTimeStamp *now,
                          const AudioBufferList *input, const AudioTimeStamp *inputTime,
                          AudioBufferList *output, const AudioTimeStamp *outputTime,
                          void *clientData) {
    SSRenderer *r = clientData;
    if (!output) return noErr;

    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        AudioBuffer *b = &output->mBuffers[i];
        if (b->mData) memset(b->mData, 0, b->mDataByteSize);
    }
    if (!r || !input || input->mNumberBuffers == 0 || output->mNumberBuffers == 0) return noErr;

    const AudioBuffer *in = &input->mBuffers[input->mNumberBuffers - 1];
    AudioBuffer *out = &output->mBuffers[0];
    const UInt32 inCh = in->mNumberChannels, outCh = out->mNumberChannels;
    if (!in->mData || !out->mData || inCh == 0 || outCh == 0) return noErr;

    const UInt32 inFrames = in->mDataByteSize / (UInt32)(sizeof(float) * inCh);
    const UInt32 outFrames = out->mDataByteSize / (UInt32)(sizeof(float) * outCh);
    const UInt32 frames = inFrames < outFrames ? inFrames : outFrames;
    if (frames == 0) return noErr;

    const float target = atomic_load_explicit(&r->targetGain, memory_order_relaxed);
    const float start = r->currentGain;
    const float step = (target - start) / (float)frames;
    const float *src = in->mData;
    float *dst = out->mData;

    for (UInt32 f = 0; f < frames; f++) {
        const float gain = start + step * (float)(f + 1);
        for (UInt32 c = 0; c < outCh; c++) {
            float s = 0.0f;
            if (c < inCh) s = src[f * inCh + c];
            else if (inCh == 1 && c == 1) s = src[f]; // mono to both speakers
            dst[f * outCh + c] = s * gain;
        }
    }
    r->currentGain = target;
    return noErr;
}

OSStatus SSUseOnlyLastInputStream(AudioObjectID device, AudioDeviceIOProcID procID) {
    AudioObjectPropertyAddress streams = {
        kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(device, &streams, 0, NULL, &size);
    if (err) return err;
    const UInt32 count = size / (UInt32)sizeof(AudioObjectID);
    if (count <= 1) return noErr; // only the tap

    const size_t bytes = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, bytes);
    usage->mIOProc = (void *)procID;
    usage->mNumberStreams = count;
    usage->mStreamIsOn[count - 1] = 1;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    err = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)bytes, usage);
    free(usage);
    return err;
}
