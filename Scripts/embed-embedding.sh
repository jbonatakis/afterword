#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="$(./Scripts/signing-identity.sh)"
app="$1"
mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/Licenses"
cp build/native/EmbeddingWorker "$app/Contents/Helpers/EmbeddingWorker"
cp build/vendor/llama.cpp/LICENSE "$app/Contents/Resources/Licenses/llama.cpp.txt"
codesign --force --sign "$SIGNING_IDENTITY" --identifier io.local.afterword.embedding --options runtime "$app/Contents/Helpers/EmbeddingWorker"
