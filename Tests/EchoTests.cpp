#include "EchoStream.h"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>
#include <random>
#include <stdexcept>
#include <vector>

static void require(bool condition, const char * message) {
    if (!condition) throw std::runtime_error(message);
}
static std::vector<float> process(const std::vector<float> & mic, const std::vector<float> & ref,
                                  size_t readSize = 481, size_t sourceSize = 73) {
    size_t m = 0, r = 0;
    auto reader = [sourceSize](const std::vector<float> & audio, size_t & at) {
        return [&audio, &at, sourceSize](float * out, size_t count) {
            size_t n = std::min({count, audio.size() - at, sourceSize});
            std::copy_n(audio.data() + at, n, out); at += n; return n;
        };
    };
    EchoStream stream(reader(mic, m), reader(ref, r), int64_t(mic.size()), int64_t(ref.size()), [] {});
    std::vector<float> result, buffer(readSize);
    while (size_t n = stream.read(buffer.data(), buffer.size())) result.insert(result.end(), buffer.begin(), buffer.begin() + n);
    require(result.size() == mic.size(), "Cleanup changed the microphone sample count");
    for (float x : result) require(std::isfinite(x), "Nonfinite cleanup output");
    return result;
}
static double energy(const std::vector<float> & x, size_t start, size_t end) {
    double sum = 0; for (size_t i = start; i < end; ++i) sum += x[i] * x[i]; return sum;
}
static double toneAmplitude(const std::vector<float> & x, size_t start, size_t end, double frequency) {
    double a = 0, b = 0;
    for (size_t i = start; i < end; ++i) {
        const double phase = 2 * M_PI * frequency * i / 16000;
        a += x[i] * std::sin(phase); b += x[i] * std::cos(phase);
    }
    return 2 * std::hypot(a, b) / (end - start);
}
static std::vector<float> file(const char * path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    require(bool(input), "Cannot open fixture"); const auto bytes = input.tellg();
    require(bytes > 0 && bytes % 4 == 0, "Invalid Float32 fixture");
    std::vector<float> values(size_t(bytes) / 4); input.seekg(0); input.read(reinterpret_cast<char *>(values.data()), bytes);
    require(bool(input), "Cannot read fixture"); return values;
}
int main(int argc, const char ** argv) {
    try {
        if (argc == 4) {
            const auto result = process(file(argv[1]), file(argv[2]));
            std::ofstream out(argv[3], std::ios::binary); out.write(reinterpret_cast<const char *>(result.data()), result.size() * 4);
            require(bool(out), "Cannot write comparison output"); return 0;
        }
        for (size_t length : {size_t(1), size_t(71), size_t(640), size_t(1667), size_t(160013)}) {
            std::vector<float> silence(length, 0);
            const auto out = process(silence, silence);
            require(std::all_of(out.begin(), out.end(), [](float x) { return std::abs(x) < 1e-6; }), "Digital silence became audible");
        }
        std::cout << "PASS short inputs, exact tail length and digital silence\n";
        const size_t n = 8 * 16000 + 71;
        std::vector<float> far(n), mic(n), near(n), zeros(n, 0);
        std::mt19937 random(42); std::uniform_real_distribution<float> noise(-0.2f, 0.2f);
        for (size_t i = 0; i < n; ++i) {
            far[i] = noise(random);
            if (i >= 4 * 16000) near[i] = 0.08f * std::sin(2 * M_PI * 700 * i / 16000);
            mic[i] = near[i];
            if (i >= 160) mic[i] += 0.35f * far[i - 160];
            if (i >= 320) mic[i] += 0.08f * far[i - 320];
        }
        const auto output = process(mic, far);
        require(output == process(mic, far, 32768, 10000), "Read boundaries reset or change the filter");
        std::cout << "PASS arbitrary decoder/output read boundaries preserve identical output\n";
        const double ratio = energy(output, 2 * 16000, 4 * 16000) / energy(mic, 2 * 16000, 4 * 16000);
        require(ratio < 0.1, "Synthetic echo was not suppressed by at least 10 dB");
        const double retained = toneAmplitude(output, 6 * 16000, 8 * 16000, 700) / 0.08;
        require(retained > 0.65 && retained < 1.15, "Local signal was lost during synthetic double-talk");
        const auto local = process(near, zeros);
        require(toneAmplitude(local, 6 * 16000, 8 * 16000, 700) / 0.08 > 0.9, "Silent reference suppressed local audio");
        std::cout << "PASS synthetic echo reduction " << -10 * std::log10(ratio) << " dB; overlapping local amplitude retained " << retained * 100 << "%\n";
        bool rejected = false;
        try { process(std::vector<float>(1000), std::vector<float>(1500)); } catch (...) { rejected = true; }
        require(rejected, "Mismatched timelines accepted");
        mic[0] = std::numeric_limits<float>::quiet_NaN(); rejected = false;
        try { process(mic, far); } catch (...) { rejected = true; }
        require(rejected, "Nonfinite input accepted");
        auto eof = [](float *, size_t) { return size_t(0); };
        rejected = false;
        try { EchoStream truncated(eof, eof, 1000, 1000, [] {}); } catch (...) { rejected = true; }
        require(rejected, "Truncated reference accepted");
        rejected = false;
        try { EchoStream cancelled(eof, eof, 1000, 1000, [] { throw std::runtime_error("cancel"); }); } catch (...) { rejected = true; }
        require(rejected, "Cancellation ignored");
        std::cout << "PASS invalid duration, truncated input, nonfinite samples and cancellation\n";
        return 0;
    } catch (const std::exception & error) { std::cerr << "FAIL " << error.what() << '\n'; return 1; }
}
