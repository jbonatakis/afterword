#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="$(./Scripts/signing-identity.sh)"
export SIGNING_IDENTITY
app="$1"
mkdir -p "$app/Contents/Helpers" "$app/Contents/Resources/Licenses"
cp Vendor/KeyboardShortcuts/license "$app/Contents/Resources/Licenses/KeyboardShortcuts.txt"
cp build/native/TranscriptionWorker "$app/Contents/Helpers/TranscriptionWorker"
cp build/vendor/transcribe.cpp/LICENSE "$app/Contents/Resources/Licenses/transcribe.cpp.txt"
cp build/vendor/transcribe.cpp/ggml/LICENSE "$app/Contents/Resources/Licenses/ggml.txt"
cp build/vendor/transcribe.cpp/src/third_party/miniz/LICENSE "$app/Contents/Resources/Licenses/miniz.txt"
cp build/vendor/transcribe.cpp/src/third_party/silero_vad/LICENSE "$app/Contents/Resources/Licenses/silero-vad.txt"
cp build/vendor/transcribe.cpp/THIRD-PARTY-LICENSES.md "$app/Contents/Resources/Licenses/EngineThirdParty.md"
cp NativeTranscription/THIRD-PARTY-NOTICES.txt "$app/Contents/Resources/Licenses/ThirdParty.txt"
echo_vendor=build/vendor/pywebrtc-audio
cp "$echo_vendor/LICENSE" "$app/Contents/Resources/Licenses/pywebrtc-audio.txt"
cp "$echo_vendor/NOTICE" "$app/Contents/Resources/Licenses/pywebrtc-audio-NOTICE.txt"
cp "$echo_vendor/vendor/webrtc_audio/abseil/LICENSE" "$app/Contents/Resources/Licenses/abseil.txt"
cp "$echo_vendor/vendor/webrtc_audio/jsoncpp/LICENSE" "$app/Contents/Resources/Licenses/jsoncpp.txt"
cp "$echo_vendor/vendor/webrtc_audio/PATENTS" "$app/Contents/Resources/Licenses/WebRTC-PATENTS.txt"
cp "$echo_vendor/vendor/webrtc_audio/AUTHORS" "$app/Contents/Resources/Licenses/WebRTC-AUTHORS.txt"
cp NativeTranscription/Echo/Licenses/*.txt "$app/Contents/Resources/Licenses/"
codesign --force --sign "$SIGNING_IDENTITY" --identifier io.local.callrecorder.transcription --options runtime "$app/Contents/Helpers/TranscriptionWorker"
