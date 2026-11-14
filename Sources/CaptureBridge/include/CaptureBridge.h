#ifndef CAPTURE_BRIDGE_H
#define CAPTURE_BRIDGE_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct CRRing CRRing;
typedef struct { uint32_t buffer, channel; } CRChannel;
typedef struct {
    uint32_t frames;
    double sampleTime;
    uint64_t hostTime;
    uint32_t timeFlags;
    bool microphoneEnabled;
} CRBlockInfo;
typedef struct {
    uint64_t callbacks, acceptedFrames, droppedFrames, invalidBuffers;
    double firstDroppedSampleTime;
    bool failed;
} CRStats;

// One producer (HAL) and one consumer (worker). All storage is allocated here.
CRRing * _Nullable CRRingCreate(uint32_t slots, uint32_t maxFrames, const uint32_t * _Nonnull bufferChannels,
                     uint32_t bufferCount, CRChannel microphone, CRChannel left, CRChannel right);
void CRRingDestroy(CRRing * _Nullable ring); // Only after stopping/destroying the IOProc.
void CRRingSetMicrophoneEnabled(CRRing * _Nonnull ring, bool enabled);
CRStats CRRingGetStats(const CRRing * _Nonnull ring);
bool CRRingRead(CRRing * _Nonnull ring, float * _Nonnull microphone, float * _Nonnull left, float * _Nonnull right, CRBlockInfo * _Nonnull info);
void CRRingPush(CRRing * _Nonnull ring, const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull time);
// Non-real-time configuration: prevent this IOProc from participating in output streams.
OSStatus CRDisableOutputStreams(AudioDeviceID device, AudioDeviceIOProcID _Nonnull ioProc);
OSStatus CRInputCallback(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                       const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                       AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime, void * _Nullable context);
#endif
