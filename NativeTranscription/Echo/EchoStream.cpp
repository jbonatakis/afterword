// The DSP sequence follows pywebrtc-audio 0.2.0's AudioProcessor (Apache-2.0).
// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// Adapted for a bounded native file stream; no Python, AGC, or noise suppression.
#include "EchoStream.h"
#include "api/echo_canceller3_factory.h"
#include "api/echo_canceller3_config.h"
#include "api/echo_control.h"
#include "audio_processing/audio_buffer.h"
#include "audio_processing/high_pass_filter.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>
#include <utility>

struct EchoStream::Implementation {
    struct Input {
        Reader reader;
        int64_t expected;
        int64_t consumed = 0;
        bool ended = false;
        size_t fill(float * output, size_t count, const CheckCancellation & check) {
            size_t used = 0;
            while (used < count && !ended) {
                check();
                const size_t n = reader(output + used, count - used);
                if (n > count - used) throw std::runtime_error("Invalid echo-cancellation input size");
                if (!n) {
                    ended = true;
                    // Sample-rate conversion can round by a single output frame.
                    if (std::abs(consumed - expected) > 1)
                        throw std::runtime_error("An audio track ended unexpectedly during speaker bleed reduction");
                }
                for (size_t i = 0; i < n; ++i) {
                    if (!std::isfinite(output[used + i]))
                        throw std::runtime_error("Invalid audio samples during speaker bleed reduction");
                }
                used += n; consumed += int64_t(n);
                if (consumed > expected + 1)
                    throw std::runtime_error("An audio track exceeded its declared duration during speaker bleed reduction");
            }
            std::fill(output + used, output + count, 0.0f);
            return used;
        }
    } microphone, reference;
    CheckCancellation check;
    std::unique_ptr<webrtc::EchoControl> aec;
    webrtc::AudioBuffer nearBuffer{16000, 1, 16000, 1, 16000, 1};
    webrtc::AudioBuffer farBuffer{16000, 1, 16000, 1, 16000, 1};
    webrtc::HighPassFilter highPass{16000, 1};
    std::array<float, frameSamples> processed{};
    size_t position = 0, available = 0;

    Implementation(Reader mic, Reader ref, int64_t micFrames, int64_t refFrames, CheckCancellation cancellation)
        : microphone{std::move(mic), micFrames}, reference{std::move(ref), refFrames}, check(std::move(cancellation)) {
        if (micFrames <= 0 || refFrames <= 0 || std::abs(micFrames - refFrames) > 1)
            throw std::runtime_error("Speaker bleed reduction requires matching microphone and system timelines");
        if (!check) check = [] {};
        check();
        webrtc::EchoCanceller3Factory factory{webrtc::EchoCanceller3Config{}};
        aec = factory.Create(16000, 1, 1);
        if (!aec) throw std::runtime_error("Cannot initialize speaker bleed reduction");
        // Supply reference look-ahead for the small negative offsets possible in
        // process-tap recordings. Only the reference cursor advances early.
        std::array<float, referenceLookaheadSamples> discard{};
        reference.fill(discard.data(), discard.size(), check);
    }

    bool nextFrame() {
        check();
        std::array<float, frameSamples> near{}, far{};
        available = microphone.fill(near.data(), near.size(), check); position = 0;
        if (!available) {
            // Verify EOF even when reference length is an exact multiple of 10 ms.
            if (reference.fill(far.data(), far.size(), check) != 0)
                throw std::runtime_error("System audio extends beyond the microphone timeline");
            return false;
        }
        reference.fill(far.data(), far.size(), check);
        for (size_t i = 0; i < frameSamples; ++i) {
            // WebRTC AudioBuffer channels use FloatS16, not normalized Float32.
            nearBuffer.channels()[0][i] = std::clamp(near[i] * 32767.0f, -32768.0f, 32767.0f);
            farBuffer.channels()[0][i] = std::clamp(far[i] * 32767.0f, -32768.0f, 32767.0f);
        }
        farBuffer.SplitIntoFrequencyBands();
        aec->AnalyzeRender(&farBuffer);
        aec->AnalyzeCapture(&nearBuffer);
        nearBuffer.SplitIntoFrequencyBands();
        highPass.Process(&nearBuffer, true);
        aec->SetAudioBufferDelay(0);
        aec->ProcessCapture(&nearBuffer, nullptr, false);
        nearBuffer.MergeFrequencyBands();
        for (size_t i = 0; i < frameSamples; ++i) {
            processed[i] = nearBuffer.channels_const()[0][i] / 32767.0f;
            if (!std::isfinite(processed[i])) throw std::runtime_error("Speaker bleed reduction returned invalid audio");
        }
        return true;
    }
};

EchoStream::EchoStream(Reader mic, Reader ref, int64_t micFrames, int64_t refFrames, CheckCancellation check)
    : impl(std::make_unique<Implementation>(std::move(mic), std::move(ref), micFrames, refFrames, std::move(check))) {}
EchoStream::~EchoStream() = default;
size_t EchoStream::read(float * output, size_t count) {
    if (!output && count) throw std::runtime_error("Missing speaker bleed reduction output buffer");
    size_t written = 0;
    while (written < count) {
        impl->check();
        if (impl->position == impl->available && !impl->nextFrame()) break;
        const size_t n = std::min(count - written, impl->available - impl->position);
        std::copy_n(impl->processed.data() + impl->position, n, output + written);
        impl->position += n; written += n;
    }
    return written;
}
