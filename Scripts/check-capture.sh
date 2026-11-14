#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 2 || "$1" != "--preview" || ! "$2" =~ ^[0-9]+$ ]]; then
    echo 'Usage: Scripts/check-capture.sh --preview DEVICE_INDEX'
    echo 'Opt-in: runs three 3-second live microphone/system audio previews; saves diagnostic numbers only.'
    exit 2
fi
SIGNING_IDENTITY="$(./Scripts/signing-identity.sh)"
export SIGNING_IDENTITY
./Scripts/swift-command.sh build
binary_dir="$(./Scripts/swift-command.sh build --show-bin-path)"
app="$PWD/build/Capture Check.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    -module-cache-path "$PWD/.build/module-cache" -I "$binary_dir/Modules" \
    -I Sources/CaptureBridge/include -framework CoreAudio -framework AVFoundation -framework AppKit \
    Tests/HardwareCaptureHarness.swift "$binary_dir"/RecorderCore.build/*.swift.o \
    "$binary_dir"/CaptureBridge.build/CaptureBridge.c.o -o "$app/Contents/MacOS/CallRecorder"
cp Configuration/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier io.local.callrecorder.capturecheck' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Call Recorder Capture Check' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Call Recorder Capture Check' "$app/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Configuration/CallRecorder.entitlements "$app"
log="$PWD/build/capture-check.log"
: > "$log"
open -n -W "$app" --args --preview "$2" "$log"
cat "$log"
rg -q '^PASS three live Start/Stop cycles' "$log"
