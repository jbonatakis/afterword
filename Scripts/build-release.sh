#!/bin/bash
# Package an Apple Silicon release using certificate-free ad-hoc signatures.
set -euo pipefail
cd "$(dirname "$0")/.."
tag="${1:-}"
version_part='(0|[1-9][0-9]*)'
if [[ ! "$tag" =~ ^v${version_part}\.${version_part}\.${version_part}$ ]]; then
    echo 'Usage: Scripts/build-release.sh vMAJOR.MINOR.PATCH' >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 || "$(git rev-parse --is-shallow-repository)" != false ]]; then
    echo 'Release builds require an Apple Silicon host and a full git checkout.' >&2
    exit 1
fi
output="$PWD/build/release"
app="$output/Afterword.app"
mkdir -p "$output"
SIGNING_IDENTITY=- AFTERWORD_RELEASE_VERSION="${tag#v}" AFTERWORD_APP_OUTPUT="$app" CONFIGURATION=release ./Scripts/build-app.sh
for binary in "$app"/Contents/MacOS/* "$app"/Contents/Helpers/*; do
    if [[ "$(lipo -archs "$binary")" != arm64 ]]; then
        echo "Unexpected architecture in $binary" >&2
        exit 1
    fi
done
archive="$output/Afterword-$tag-macOS-arm64.zip"
stage="$(mktemp -d "$output/.packaging.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/release.zip"
mv -f "$stage/release.zip" "$archive"
echo "Packaged $archive"
