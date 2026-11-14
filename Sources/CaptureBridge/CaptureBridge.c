#include "CaptureBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Real-time counters must be lock free");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Real-time indexes must be lock free");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "Real-time mute flags must be lock free");
struct CRRing {
    uint32_t slots, maxFrames, bufferCount, channels[64];
    CRChannel mic, left, right;
    float *samples;
    CRBlockInfo *info;
    _Atomic uint64_t write, read, callbacks, accepted, dropped, invalid;
    _Atomic uint64_t firstDroppedBits;
    _Atomic bool micEnabled, failed;
};

CRRing *CRRingCreate(uint32_t slots, uint32_t maxFrames, const uint32_t *channels,
                    uint32_t count, CRChannel mic, CRChannel left, CRChannel right) {
    if (slots < 2 || slots > 256 || !maxFrames || maxFrames > 16384 || !count || count > 64) return NULL;
    CRChannel refs[] = {mic, left, right};
    for (int i=0; i<3; ++i)
        if (refs[i].buffer >= count || refs[i].channel >= channels[refs[i].buffer]) return NULL;
    CRRing *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->samples = calloc((size_t)slots * maxFrames * 3, sizeof(float));
    r->info = calloc(slots, sizeof(CRBlockInfo));
    if (!r->samples || !r->info) { CRRingDestroy(r); return NULL; }
    r->slots = slots; r->maxFrames = maxFrames; r->bufferCount = count;
    memcpy(r->channels, channels, count * sizeof(uint32_t));
    r->mic = mic; r->left = left; r->right = right;
    atomic_init(&r->micEnabled, true);
    return r;
}
void CRRingDestroy(CRRing *r) { if (r) { free(r->samples); free(r->info); free(r); } }
void CRRingSetMicrophoneEnabled(CRRing *r, bool on) { atomic_store_explicit(&r->micEnabled, on, memory_order_relaxed); }
CRStats CRRingGetStats(const CRRing *r) {
    CRStats s = {0};
    s.callbacks = atomic_load(&r->callbacks); s.acceptedFrames = atomic_load(&r->accepted);
    s.droppedFrames = atomic_load(&r->dropped); s.invalidBuffers = atomic_load(&r->invalid);
    s.failed = atomic_load_explicit(&r->failed, memory_order_acquire);
    uint64_t bits = atomic_load(&r->firstDroppedBits);
    memcpy(&s.firstDroppedSampleTime, &bits, sizeof(bits));
    return s;
}
static void fail(CRRing *r, uint32_t frames, double sampleTime, bool invalid) {
    if (!atomic_load(&r->failed)) {
        uint64_t bits; memcpy(&bits, &sampleTime, sizeof(bits));
        atomic_store(&r->firstDroppedBits, bits);
    }
    if (invalid) atomic_fetch_add(&r->invalid, 1);
    atomic_fetch_add(&r->dropped, frames);
    atomic_store_explicit(&r->failed, true, memory_order_release);
}
void CRRingPush(CRRing *r, const AudioBufferList *input, const AudioTimeStamp *time) {
    atomic_fetch_add_explicit(&r->callbacks, 1, memory_order_relaxed);
    if (!input || !time || input->mNumberBuffers != r->bufferCount) { fail(r, 0, 0, true); return; }
    CRChannel refs[] = {r->mic, r->left, r->right};
    uint32_t frames = 0;
    for (int i=0; i<3; ++i) {
        const AudioBuffer *b = &input->mBuffers[refs[i].buffer];
        if (!b->mData || b->mNumberChannels != r->channels[refs[i].buffer] || !b->mNumberChannels ||
            b->mDataByteSize % (sizeof(float) * b->mNumberChannels)) { fail(r, frames, time->mSampleTime, true); return; }
        uint32_t n = b->mDataByteSize / (sizeof(float) * b->mNumberChannels);
        if (i && frames != n) { fail(r, frames, time->mSampleTime, true); return; }
        frames = n;
    }
    if (!frames) return;
    if (atomic_load(&r->failed)) { atomic_fetch_add(&r->dropped, frames); return; }
    if (frames > r->maxFrames || !(time->mFlags & kAudioTimeStampSampleTimeValid)) { fail(r, frames, time->mSampleTime, true); return; }
    uint64_t w = atomic_load_explicit(&r->write, memory_order_relaxed);
    if (w - atomic_load_explicit(&r->read, memory_order_acquire) >= r->slots) { fail(r, frames, time->mSampleTime, false); return; }
    uint32_t slot = (uint32_t)(w % r->slots);
    bool micOn = atomic_load_explicit(&r->micEnabled, memory_order_relaxed);
    r->info[slot] = (CRBlockInfo){frames, time->mSampleTime, time->mHostTime, time->mFlags, micOn};
    for (int source=0; source<3; ++source) {
        const AudioBuffer *b = &input->mBuffers[refs[source].buffer];
        const float *src = b->mData;
        float *dst = r->samples + ((size_t)slot * 3 + source) * r->maxFrames;
        if (source == 0 && !micOn) memset(dst, 0, frames * sizeof(float));
        else for (uint32_t f=0; f<frames; ++f) dst[f] = src[f * b->mNumberChannels + refs[source].channel];
    }
    atomic_fetch_add_explicit(&r->accepted, frames, memory_order_relaxed);
    atomic_store_explicit(&r->write, w + 1, memory_order_release);
}
bool CRRingRead(CRRing *r, float *mic, float *left, float *right, CRBlockInfo *info) {
    uint64_t read = atomic_load_explicit(&r->read, memory_order_relaxed);
    if (read == atomic_load_explicit(&r->write, memory_order_acquire)) return false;
    uint32_t slot = (uint32_t)(read % r->slots);
    *info = r->info[slot];
    float *dest[] = {mic, left, right};
    for (int i=0; i<3; ++i) memcpy(dest[i], r->samples + ((size_t)slot * 3 + i) * r->maxFrames, info->frames * sizeof(float));
    atomic_store_explicit(&r->read, read + 1, memory_order_release);
    return true;
}
OSStatus CRInputCallback(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                       const AudioTimeStamp *inputTime, AudioBufferList *output,
                       const AudioTimeStamp *outputTime, void *context) {
    // All output streams for this IOProc are disabled during preparation.
    if (context) CRRingPush((CRRing *)context, input, inputTime);
    return noErr;
}
OSStatus CRDisableOutputStreams(AudioDeviceID device, AudioDeviceIOProcID ioProc) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    if (status != noErr || size == 0) return status;
    UInt32 count = size / sizeof(AudioStreamID);
    if (count > 4096) return kAudioHardwareBadPropertySizeError;
    size = (UInt32)(offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32));
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)ioProc; usage->mNumberStreams = count;
    address.mSelector = kAudioDevicePropertyIOProcStreamUsage;
    status = AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
    free(usage);
    return status;
}
