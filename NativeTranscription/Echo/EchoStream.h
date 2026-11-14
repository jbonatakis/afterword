#pragma once
#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>

// A single sequential stream: 16 kHz mono Float32 in/out. The system reader
// supplies the arithmetic mean of its stereo channels. No capture samples move.
class EchoStream {
public:
    static constexpr size_t sampleRate = 16000;
    static constexpr size_t frameSamples = 160;
    static constexpr size_t referenceLookaheadSamples = 640;
    static constexpr const char * engine = "WebRTC AEC3 / pywebrtc-audio 0.2.0";
    using Reader = std::function<size_t(float *, size_t)>;
    using CheckCancellation = std::function<void()>;

    EchoStream(Reader microphone, Reader reference, int64_t microphoneFrames,
               int64_t referenceFrames, CheckCancellation checkCancellation);
    ~EchoStream();
    size_t read(float * output, size_t count);
    EchoStream(const EchoStream &) = delete;
    EchoStream & operator=(const EchoStream &) = delete;
private:
    struct Implementation;
    std::unique_ptr<Implementation> impl;
};
