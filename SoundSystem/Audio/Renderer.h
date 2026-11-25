#ifndef SOUNDSYSTEM_RENDERER_H
#define SOUNDSYSTEM_RENDERER_H

#include <CoreAudio/CoreAudio.h>

CF_ASSUME_NONNULL_BEGIN

/// Real-time state for one adjusted app. Written in C so the audio thread never
/// touches the Swift runtime (no locks, no allocation, no reference counting).
typedef struct SSRenderer SSRenderer;

SSRenderer *SSRendererCreate(float initialGain);
void SSRendererDestroy(SSRenderer *renderer);

/// Safe to call from any thread; the audio thread ramps to the new gain.
void SSRendererSetGain(SSRenderer *renderer, float gain);

/// Device IOProc: copies the tap (last input stream) to the first output stream, scaled.
OSStatus SSRendererIOProc(AudioObjectID device,
                          const AudioTimeStamp *now,
                          const AudioBufferList *input,
                          const AudioTimeStamp *inputTime,
                          AudioBufferList *output,
                          const AudioTimeStamp *outputTime,
                          void *_Nullable clientData);

/// Turns off every input stream except the last one (the tap), so adjusting an app never
/// opens the microphone on devices that have both inputs and outputs.
OSStatus SSUseOnlyLastInputStream(AudioObjectID device, AudioDeviceIOProcID procID);

CF_ASSUME_NONNULL_END

#endif
