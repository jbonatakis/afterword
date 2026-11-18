#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="$(./Scripts/signing-identity.sh)"
export SIGNING_IDENTITY
configuration="${CONFIGURATION:-release}"
./Scripts/build-transcription.sh
./Scripts/build-embedding.sh
./Scripts/build-diarization.sh
./Scripts/swift-command.sh build -c "$configuration"
binary_dir="$(./Scripts/swift-command.sh build -c "$configuration" --show-bin-path)"
app="${AFTERWORD_APP_OUTPUT:-$PWD/build/Afterword.app}"
mkdir -p build
stage_root="$(mktemp -d "$PWD/build/.afterword-build.XXXXXX")"
trap 'rm -rf "$stage_root"' EXIT
stage_app="$stage_root/Afterword.app"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$binary_dir/Afterword" "$stage_app/Contents/MacOS/Afterword"
cp Configuration/Info.plist "$stage_app/Contents/Info.plist"
if [[ -n "${AFTERWORD_GITHUB_CLIENT_ID:-}" ]]; then
    plutil -replace AfterwordGitHubClientID -string "$AFTERWORD_GITHUB_CLIENT_ID" "$stage_app/Contents/Info.plist"
fi
cp -R "$binary_dir/KeyboardShortcuts_KeyboardShortcuts.bundle" "$binary_dir/Afterword_Afterword.bundle" "$stage_app/Contents/Resources/"
./Scripts/embed-transcription.sh "$stage_app"
./Scripts/embed-embedding.sh "$stage_app"
./Scripts/embed-diarization.sh "$stage_app"
cp "$binary_dir/AfterwordMCP" "$stage_app/Contents/Helpers/AfterwordMCP"
codesign --force --sign "$SIGNING_IDENTITY" --identifier io.local.afterword.mcp --options runtime "$stage_app/Contents/Helpers/AfterwordMCP"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime --entitlements Configuration/Afterword.entitlements "$stage_app"
codesign --verify --deep --strict "$stage_app"
python3 - "$stage_app" "$app" "$stage_root/previous.app" <<'PY_INSTALL'
import os, plistlib, sys
stage, destination, backup = sys.argv[1:]
# Permit the one-time update from the original app identity.
if os.path.lexists(destination):
    if os.path.islink(destination):
        raise RuntimeError("Unexpected app link at " + destination)
    with open(os.path.join(destination, "Contents", "Info.plist"), "rb") as file:
        if plistlib.load(file).get("CFBundleIdentifier") not in {"io.local.afterword", "io.local.callrecorder"}:
            raise RuntimeError("Refusing to replace another application at " + destination)
archived = False
installed = False
try:
    if os.path.lexists(destination):
        os.rename(destination, backup)
        archived = True
    os.rename(stage, destination)
    installed = True
except BaseException:
    if installed:
        os.rename(destination, stage)
    if archived:
        os.rename(backup, destination)
    raise
PY_INSTALL
codesign --verify --deep --strict "$app"
echo "Built $app"
