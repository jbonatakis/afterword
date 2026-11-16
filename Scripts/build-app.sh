#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="$(./Scripts/signing-identity.sh)"
export SIGNING_IDENTITY
configuration="${CONFIGURATION:-release}"
./Scripts/build-transcription.sh
./Scripts/build-embedding.sh
./Scripts/swift-command.sh build -c "$configuration"
binary_dir="$(./Scripts/swift-command.sh build -c "$configuration" --show-bin-path)"
app="$PWD/build/Afterword.app"
legacy_app="$PWD/build/Call Recorder.app"
mkdir -p build
stage_root="$(mktemp -d "$PWD/build/.call-recorder-build.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage_app="$stage_root/Afterword.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$binary_dir/CallRecorder" "$stage_app/Contents/MacOS/CallRecorder"
cp Configuration/Info.plist "$stage_app/Contents/Info.plist"
cp -R "$binary_dir/KeyboardShortcuts_KeyboardShortcuts.bundle" "$stage_app/Contents/Resources/"
./Scripts/embed-transcription.sh "$stage_app"
./Scripts/embed-embedding.sh "$stage_app"
cp "$binary_dir/CallRecorderMCP" "$stage_app/Contents/Helpers/CallRecorderMCP"
codesign --force --sign "$SIGNING_IDENTITY" --identifier io.local.callrecorder.mcp --options runtime "$stage_app/Contents/Helpers/CallRecorderMCP"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Configuration/CallRecorder.entitlements "$stage_app"
codesign --verify --deep --strict "$stage_app"
python3 - "$stage_app" "$app" "$stage_root/previous.app" "$legacy_app" <<'PY_INSTALL'
import os, plistlib, sys
stage, destination, backup, legacy = sys.argv[1:]
legacy_backup = os.path.join(os.path.dirname(backup), "legacy.app")
link_stage = os.path.join(os.path.dirname(backup), "legacy-link")
# Only replace this product's prior builds. Keep legacy MCP commands resolving
# to the current signed helper without retaining a second stale application.
for path in (destination, legacy):
    if not os.path.lexists(path):
        continue
    if os.path.islink(path):
        if path != legacy or os.readlink(path) != os.path.basename(destination):
            raise RuntimeError("Unexpected app link at " + path)
    else:
        with open(os.path.join(path, "Contents", "Info.plist"), "rb") as file:
            if plistlib.load(file).get("CFBundleIdentifier") != "io.local.callrecorder":
                raise RuntimeError("Refusing to replace another application at " + path)
os.symlink(os.path.basename(destination), link_stage)
archived = []
installed = False
try:
    if os.path.lexists(destination):
        os.rename(destination, backup)
        archived.append((backup, destination))
    os.rename(stage, destination)
    installed = True
    if os.path.lexists(legacy):
        os.rename(legacy, legacy_backup)
        archived.append((legacy_backup, legacy))
    os.replace(link_stage, legacy)
except BaseException:
    if installed:
        os.rename(destination, stage)
    for previous, original in reversed(archived):
        os.rename(previous, original)
    raise
PY_INSTALL
codesign --verify --deep --strict "$app"
echo "Built $app"
