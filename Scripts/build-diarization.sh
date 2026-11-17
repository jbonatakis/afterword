#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD/build/diarization"
revision=16780f04d2ece24f67d0fc00efccd0296491c1a8
mkdir -p "$root/package/Sources/SpeakerWorker" build/native
if [ ! -d "$root/upstream.git" ]; then git init -q --bare "$root/upstream.git"; fi
if ! git -C "$root/upstream.git" cat-file -e "$revision^{commit}" 2>/dev/null; then
    GIT_TERMINAL_PROMPT=0 git -c credential.helper= -C "$root/upstream.git" fetch -q --depth 1 https://github.com/FluidInference/FluidAudio.git "$revision"
fi
if [ "$(cat "$root/source-revision" 2>/dev/null || true)" != "$revision" ]; then
    git -C "$root/upstream.git" archive "$revision" Sources/{FluidAudio,FastClusterWrapper,MachTaskSelfWrapper} LICENSE ThirdPartyLicenses/{fastcluster,vbx}-LICENSE.md | tar -xf - -C "$root/package"
    echo "$revision" > "$root/source-revision"
fi
cp NativeDiarization/Package.swift "$root/package/Package.swift"
cp NativeDiarization/main.swift Sources/RecorderCore/SpeakerAnalysis.swift "$root/package/Sources/SpeakerWorker/"
./Scripts/swift-command.sh build --disable-keychain --disable-netrc --package-path "$root/package" -c release -j 3 --product SpeakerWorker
cp "$root/package/.build/release/SpeakerWorker" build/native/SpeakerWorker
python3 NativeDiarization/fetch-model.py "$root/models/speaker-diarization"
