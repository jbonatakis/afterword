#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=c22473b580807929fd9e3a3344a48e8cfbe6c88f
vendor="$PWD/build/vendor/llama.cpp"
mkdir -p build/vendor build/native
if [ ! -d "$vendor/.git" ]; then
    git clone --depth 1 --branch b6900 https://github.com/ggml-org/llama.cpp.git "$vendor"
fi
if [ "$(git -C "$vendor" rev-parse HEAD)" != "$revision" ]; then
    git -C "$vendor" fetch origin "$revision"
    git -C "$vendor" checkout --detach "$revision"
fi
export UV_CACHE_DIR="$PWD/build/native-tools"
cmake_run() { uv run --no-project --no-managed-python --python 3.12 --with cmake==3.31.6 cmake "$@"; }
cmake_run -S "$vendor" -B build/native/embedding -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_CURL=OFF -DLLAMA_BUILD_COMMON=OFF -DGGML_METAL_EMBED_LIBRARY=ON
cmake_run --build build/native/embedding --target llama -j 6
libraries=()
while IFS= read -r library; do libraries+=("$library"); done < <(find "$PWD/build/native/embedding" -name '*.a' -type f | sort)
xcrun clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=14.2 \
    -I "$vendor/include" -I "$vendor/ggml/include" NativeEmbedding/Worker.mm "${libraries[@]}" \
    -framework Foundation -framework Accelerate -framework Metal -framework MetalKit \
    -o build/native/EmbeddingWorker
