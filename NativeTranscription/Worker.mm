#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "transcribe.h"
#include "EchoStream.h"
#include <array>
#include <algorithm>
#include <cmath>
#include <csignal>
#include <memory>
#include <stdexcept>
#include <vector>
#include <unistd.h>

// One process owns one model. No audio or transcripts cross a network boundary.
static volatile sig_atomic_t cancelled = 0;
static void cancel(int) { cancelled = 1; }
static void checkCancel() { if (cancelled) throw std::runtime_error("Cancelled"); }
static void check(OSStatus status, const char * action) {
    if (status) throw std::runtime_error(std::string(action) + " (" + std::to_string(status) + ")");
}
static void checkASR(transcribe_status status) {
    if (status != TRANSCRIBE_OK) throw std::runtime_error(transcribe_status_string(status));
}
static void emit(NSDictionary * value) {
    NSData * data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data || fwrite(data.bytes, 1, data.length, stdout) != data.length || fputc('\n', stdout) == EOF)
        throw std::runtime_error("Cannot write transcription result");
    fflush(stdout);
}
static NSString * clean(const char * text) {
    return [[NSString stringWithUTF8String:text ?: ""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}
static void segment(NSString * source, NSString * text, double start, double end, NSString * timing) {
    if (!text.length) return;
    emit(@{@"type": @"segment", @"source": source, @"text": text,
           @"start": @(start), @"end": @(end), @"timing": timing});
}

struct AudioReader {
    ExtAudioFileRef file = nullptr;
    double duration = 0;
    UInt32 channels = 1;
    UInt32 sourceChannels = 0;
    explicit AudioReader(NSString * path, UInt32 outputChannels = 1) : channels(outputChannels) {
        try {
            NSURL * url = [NSURL fileURLWithPath:path];
            check(ExtAudioFileOpenURL((__bridge CFURLRef)url, &file), "Cannot open audio");
            AudioStreamBasicDescription source = {}; UInt32 size = sizeof(source);
            check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source), "Cannot read audio format");
            SInt64 frames = 0; size = sizeof(frames);
            check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames), "Cannot read audio duration");
            if (source.mSampleRate <= 0 || frames <= 0 || source.mChannelsPerFrame > 2)
                throw std::runtime_error("Expected nonempty mono or stereo audio");
            duration = double(frames) / source.mSampleRate;
            sourceChannels = source.mChannelsPerFrame;
            AudioStreamBasicDescription target = {};
            target.mSampleRate = 16000; target.mFormatID = kAudioFormatLinearPCM;
            target.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
            target.mBytesPerPacket = target.mBytesPerFrame = sizeof(float) * channels;
            target.mFramesPerPacket = 1; target.mChannelsPerFrame = channels; target.mBitsPerChannel = 32;
            check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(target), &target), "Cannot decode audio");
        } catch (...) { if (file) ExtAudioFileDispose(file); throw; }
    }
    ~AudioReader() { if (file) ExtAudioFileDispose(file); }
    UInt32 read(float * output, UInt32 count) {
        AudioBufferList buffer = {1, {{channels, count * channels * UInt32(sizeof(float)), output}}};
        check(ExtAudioFileRead(file, &count, &buffer), "Audio decode failed"); return count;
    }
};

static void results(transcribe_session * session, NSString * source, int64_t offset, size_t count) {
    const double origin = double(offset) / 16000, length = double(count) / 16000;
    auto time = [=](int64_t ms) { return origin + std::clamp(double(ms) / 1000, 0.0, length); };
    const auto kind = transcribe_returned_timestamp_kind(session);
    if (kind >= TRANSCRIBE_TIMESTAMPS_WORD && transcribe_n_words(session) > 0) {
        NSMutableString * phrase = [NSMutableString string]; double start = 0, end = 0;
        for (int i = 0; i < transcribe_n_words(session); ++i) {
            transcribe_word word; transcribe_word_init(&word); checkASR(transcribe_get_word(session, i, &word));
            NSString * text = clean(word.text); if (!text.length) continue;
            double a = time(word.t0_ms), b = std::max(a, time(word.t1_ms));
            if (phrase.length && (a - end > 0.65 || b - start > 8)) {
                segment(source, phrase, start, end, @"word"); phrase = [NSMutableString string];
            }
            if (!phrase.length) start = a; else [phrase appendString:@" "];
            [phrase appendString:text]; end = b;
            if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@".!?。！？"] options:NSBackwardsSearch].location == text.length - 1) {
                segment(source, phrase, start, end, @"word"); phrase = [NSMutableString string];
            }
        }
        segment(source, phrase, start, end, @"word");
    } else if (kind >= TRANSCRIBE_TIMESTAMPS_SEGMENT && transcribe_n_segments(session) > 0) {
        for (int i = 0; i < transcribe_n_segments(session); ++i) {
            transcribe_segment row; transcribe_segment_init(&row); checkASR(transcribe_get_segment(session, i, &row));
            const double a = time(row.t0_ms);
            segment(source, clean(row.text), a, std::max(a, time(row.t1_ms)), @"segment");
        }
    } else {
        segment(source, clean(transcribe_full_text(session)), origin, origin + length, @"chunk");
    }
}

static void transcribeTrack(transcribe_session * session, NSDictionary * track, int index, int total, NSString * language, NSString * referencePath) {
    NSString * source = track[@"source"], * path = track[@"path"];
    if (![source isKindOfClass:NSString.class] || ![path isKindOfClass:NSString.class]) throw std::runtime_error("Invalid track");
    AudioReader reader(path);
    std::unique_ptr<AudioReader> reference;
    std::unique_ptr<EchoStream> echo;
    if (referencePath) {
        reference = std::make_unique<AudioReader>(referencePath, 2);
        if (reader.sourceChannels != 1 || reference->sourceChannels != 2)
            throw std::runtime_error("Speaker bleed reduction requires a mono microphone and stereo system track");
        echo = std::make_unique<EchoStream>(
            [&](float * out, size_t count) { return reader.read(out, UInt32(count)); },
            [&](float * out, size_t count) {
                std::array<float, EchoStream::referenceLookaheadSamples * 2> stereo{};
                if (count > stereo.size() / 2) throw std::runtime_error("Invalid reference read size");
                const size_t n = reference->read(stereo.data(), UInt32(count));
                for (size_t i = 0; i < n; ++i) out[i] = (stereo[2 * i] + stereo[2 * i + 1]) * 0.5f;
                return n;
            }, int64_t(std::llround(reader.duration * 16000)),
            int64_t(std::llround(reference->duration * 16000)), checkCancel);
    }
    emit(@{@"type": @"track", @"source": source, @"duration": @(reader.duration)});
    // Bound decoded audio to 30 seconds, retaining every sample and its original offset.
    // Prefer a quiet cut between 24 and 30 seconds; continuous speech may cross a cut.
    constexpr size_t capacity = 30 * 16000;
    std::vector<float> pcm(capacity); size_t used = 0; int64_t offset = 0; bool eof = false;
    while (!eof || used) {
        checkCancel();
        if (echo) emit(@{@"type": @"cleanup", @"source": source});
        while (!eof && used < capacity) {
            const size_t n = echo ? echo->read(pcm.data() + used, capacity - used) : reader.read(pcm.data() + used, UInt32(capacity - used));
            used += n; if (!n) eof = true;
        }
        if (!used) break;
        if (echo) emit(@{@"type": @"progress", @"source": source,
                         @"progress": @((index + std::min(1.0, double(offset) / 16000 / reader.duration)) / total)});
        size_t count = used;
        if (!eof && used == capacity) {
            double quietest = 1e100; size_t best = capacity;
            for (size_t at = 24 * 16000; at + 1600 <= used; at += 800) {
                double energy = 0; for (size_t j = at; j < at + 1600; ++j) energy += pcm[j] * pcm[j];
                if (energy < quietest) { quietest = energy; best = at + 800; }
            }
            if (quietest / 1600 < 0.00001) count = best;
        }
        double peak = 0;
        for (size_t i = 0; i < count; ++i) {
            if (!std::isfinite(pcm[i])) throw std::runtime_error("Audio contains invalid samples");
            peak = std::max(peak, double(std::abs(pcm[i])));
        }
        // Skip digital silence (including negligible AAC noise), not ordinary quiet speech.
        if (peak > 0.00001) {
            transcribe_run_params params; transcribe_run_params_init(&params);
            params.language = [language isEqualToString:@"auto"] ? nullptr : language.UTF8String;
            checkASR(transcribe_run(session, pcm.data(), int(count), &params));
            checkCancel(); results(session, source, offset, count);
        }
        offset += count;
        emit(@{@"type": @"progress", @"source": source,
               @"progress": @((index + std::min(1.0, double(offset) / 16000 / reader.duration)) / total)});
        std::move(pcm.begin() + count, pcm.begin() + used, pcm.begin()); used -= count;
    }
}

int main(int argc, const char ** argv) {
    @autoreleasepool {
        signal(SIGTERM, cancel); signal(SIGINT, cancel); signal(SIGPIPE, SIG_IGN);
        nice(10);
        transcribe_log_set([](transcribe_log_level level, const char * message, void *) {
            if (level == TRANSCRIBE_LOG_LEVEL_WARN || level == TRANSCRIBE_LOG_LEVEL_ERROR) fputs(message, stderr);
        }, nullptr);
        try {
            if (argc != 2) throw std::runtime_error("Expected one JSON request path");
            NSData * data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
            NSDictionary * request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![request isKindOfClass:NSDictionary.class] || ![request[@"model"] isKindOfClass:NSString.class] ||
                ![request[@"tracks"] isKindOfClass:NSArray.class] || [request[@"tracks"] count] < 1 || [request[@"tracks"] count] > 2)
                throw std::runtime_error("Invalid transcription request");
            NSArray * tracks = request[@"tracks"];
            NSString * referencePath = nil;
            bool hasMicrophone = false;
            for (id track in tracks) {
                if (![track isKindOfClass:NSDictionary.class] || ![track[@"source"] isKindOfClass:NSString.class] || ![track[@"path"] isKindOfClass:NSString.class])
                    throw std::runtime_error("Invalid transcription track");
                if ([track[@"source"] isEqualToString:@"microphone"]) hasMicrophone = true;
                if ([track[@"source"] isEqualToString:@"system"]) referencePath = track[@"path"];
            }
            const bool requested = request[@"reduceSpeakerBleed"] == nil || [request[@"reduceSpeakerBleed"] boolValue];
            const bool reduceBleed = requested && hasMicrophone && referencePath && tracks.count == 2;
            emit(@{@"type": @"loading"});
            transcribe_model_load_params load; transcribe_model_load_params_init(&load);
            transcribe_model * rawModel = nullptr;
            checkASR(transcribe_model_load_file([request[@"model"] UTF8String], &load, &rawModel));
            std::unique_ptr<transcribe_model, decltype(&transcribe_model_free)> model(rawModel, transcribe_model_free);
            checkCancel();
            transcribe_session_params params; transcribe_session_params_init(&params); params.n_threads = 4;
            transcribe_session * rawSession = nullptr; checkASR(transcribe_session_init(model.get(), &params, &rawSession));
            std::unique_ptr<transcribe_session, decltype(&transcribe_session_free)> session(rawSession, transcribe_session_free);
            transcribe_set_abort_callback(session.get(), [](void *) { return cancelled != 0; }, nullptr);
            NSString * language = [request[@"language"] isKindOfClass:NSString.class] ? request[@"language"] : @"auto";
            for (NSUInteger i = 0; i < tracks.count; ++i) {
                @autoreleasepool {
                    const bool microphone = [tracks[i][@"source"] isEqualToString:@"microphone"];
                    transcribeTrack(session.get(), tracks[i], int(i), int(tracks.count), language, reduceBleed && microphone ? referencePath : nil);
                }
            }
            checkCancel();
            NSMutableDictionary * done = [@{@"type": @"done", @"engine": [NSString stringWithUTF8String:transcribe_version()],
                                             @"speakerBleedReductionApplied": @(reduceBleed)} mutableCopy];
            if (reduceBleed) done[@"echoCancellation"] = @{@"engine": [NSString stringWithUTF8String:EchoStream::engine],
                                                          @"referenceLookaheadMilliseconds": @40, @"sampleRate": @16000};
            emit(done);
            return 0;
        } catch (const std::exception & error) {
            try { emit(@{@"type": @"error", @"message": [NSString stringWithUTF8String:error.what()] ?: @"Transcription failed"}); } catch (...) {}
            return cancelled ? 130 : 1;
        }
    }
}
