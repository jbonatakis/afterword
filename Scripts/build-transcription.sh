#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=275cd50d2c4104c204009a197ac091b9687668e5
vendor="$PWD/build/vendor/transcribe.cpp"
mkdir -p build/vendor build/native
if [ ! -d "$vendor/.git" ]; then
    git clone https://github.com/handy-computer/transcribe.cpp.git "$vendor"
fi
if [ "$(git -C "$vendor" rev-parse HEAD)" != "$revision" ]; then
    git -C "$vendor" fetch origin "$revision"
    git -C "$vendor" checkout --detach "$revision"
fi
git -C "$vendor" submodule update --init --recursive --depth 1
export UV_CACHE_DIR="$PWD/build/native-tools"
cmake_run() { uv run --no-project --no-managed-python --python 3.12 --with cmake==3.31.6 cmake "$@"; }
cmake_run -S "$vendor" -B build/native/engine -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 -DTRANSCRIBE_BUILD_SHARED=OFF \
    -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
    -DTRANSCRIBE_BUILD_TOOLS=OFF -DGGML_METAL_EMBED_LIBRARY=ON
cmake_run --build build/native/engine --target transcribe -j 6
echo_revision=1bc860a2051c2b9b3c10b8c778770794b9321d84
echo_vendor="$PWD/build/vendor/pywebrtc-audio"
if [ ! -d "$echo_vendor/.git" ]; then
    git clone https://github.com/strands-labs/pywebrtc-audio.git "$echo_vendor"
fi
if [ "$(git -C "$echo_vendor" rev-parse HEAD)" != "$echo_revision" ]; then
    git -C "$echo_vendor" fetch origin "$echo_revision"
    git -C "$echo_vendor" checkout --detach "$echo_revision"
fi
cmake_run -S NativeTranscription/Echo -B build/native/echo -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 -DWEBRTC_SOURCE="$echo_vendor/vendor/webrtc_audio"
cmake_run --build build/native/echo -j 6
libraries=()
while IFS= read -r library; do libraries+=("$library"); done < <(find "$PWD/build/native/engine" -name '*.a' -type f | sort)
xcrun clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=14.2 \
    -I "$vendor/include" -I NativeTranscription/Echo NativeTranscription/Worker.mm "${libraries[@]}" \
    build/native/echo/libRecorderEcho.a build/native/echo/webrtc/libwebrtc_audio_static.a \
    -framework Foundation -framework AudioToolbox -framework Accelerate \
    -framework Metal -framework MetalKit -framework CoreFoundation \
    -o build/native/TranscriptionWorker
echo "Built local transcription worker ($revision)"
