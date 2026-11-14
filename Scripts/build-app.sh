#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="$(./Scripts/signing-identity.sh)"
export SIGNING_IDENTITY
configuration="${CONFIGURATION:-release}"
./Scripts/build-transcription.sh
./Scripts/swift-command.sh build -c "$configuration"
binary_dir="$(./Scripts/swift-command.sh build -c "$configuration" --show-bin-path)"
app="$PWD/build/Call Recorder.app"
mkdir -p build
stage_root="$(mktemp -d "$PWD/build/.call-recorder-build.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage_app="$stage_root/Call Recorder.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$binary_dir/CallRecorder" "$stage_app/Contents/MacOS/CallRecorder"
cp Configuration/Info.plist "$stage_app/Contents/Info.plist"
cp -R "$binary_dir/KeyboardShortcuts_KeyboardShortcuts.bundle" "$stage_app/Contents/Resources/"
./Scripts/embed-transcription.sh "$stage_app"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Configuration/CallRecorder.entitlements "$stage_app"
codesign --verify --deep --strict "$stage_app"
python3 - "$stage_app" "$app" "$stage_root/previous.app" <<'PY'
import os,sys
stage, destination, backup = sys.argv[1:]
existed = os.path.exists(destination)
if existed: os.rename(destination, backup)
try: os.rename(stage, destination)
except BaseException:
    if existed: os.rename(backup, destination)
    raise
PY
codesign --verify --deep --strict "$app"
echo "Built $app"
