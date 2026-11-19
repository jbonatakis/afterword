#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Library Check.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.local.afterword.librarycheck</string>
<key>CFBundleExecutable</key><string>LibraryCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
harness=Tests/LibraryHarness.swift
if [[ $# -gt 0 && "$1" != -* ]]; then
    harness="$1"
    shift
fi
build_args=(-c debug)
if [[ "${1:-}" == "--release" ]]; then
    shift
    optimization=(-O -whole-module-optimization)
    build_args=(-c release -Xswiftc -enable-testing)
elif [[ "${1:-}" == "--optimized" ]]; then
    shift
    optimization=(-O)
else
    optimization=(-Onone)
fi
./Scripts/swift-command.sh build "${build_args[@]}"
binary_dir="$(./Scripts/swift-command.sh build "${build_args[@]}" --show-bin-path)"
objects="$(mktemp "$PWD/build/library-link.XXXXXX")"
trap 'rm -f "$objects"' EXIT
grep -v '/Afterword.build/' "$binary_dir/Afterword.product/Objects.LinkFileList" > "$objects"
xcrun swiftc "${optimization[@]}" -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    -module-cache-path "$PWD/.build/module-cache" -I "$binary_dir/Modules" \
    -I Sources/CaptureBridge/include -framework CoreAudio -framework AVFoundation -lsqlite3 -framework Carbon -framework IOKit -framework EventKit \
    "$harness" Sources/Afterword/LibrarySummaryMonitor.swift Sources/Afterword/CallSummaryView.swift Sources/Afterword/MarkdownContent.swift Sources/Afterword/EmbeddingSettings.swift Sources/Afterword/RecordingLibraryModel.swift Sources/Afterword/RecordingLibraryView.swift Sources/Afterword/CodingSessions.swift Sources/Afterword/GitHubConnection.swift Sources/Afterword/GitHubViews.swift Sources/Afterword/GitHubRepositoryPicker.swift Sources/Afterword/RecordingLibraryWindow.swift Sources/Afterword/LibraryKeyboard.swift Sources/Afterword/CallEditors.swift Sources/Afterword/AttendanceEditor.swift Sources/Afterword/CalendarCoordinator.swift Sources/Afterword/CalendarViews.swift Sources/Afterword/SpeakerReviewSheet.swift Sources/Afterword/PersonVoiceClipsView.swift \
    Sources/Afterword/RecordingCoordinator.swift Sources/Afterword/RecordingShortcut.swift Sources/Afterword/TranscriptionCoordinator.swift \
    -Xlinker -filelist -Xlinker "$objects" -o "$app/Contents/MacOS/LibraryCheck"
cp Sources/Afterword/Resources/*.png "$app/Contents/Resources/"
cp -R "$binary_dir/KeyboardShortcuts_KeyboardShortcuts.bundle" "$app/Contents/Resources/"
codesign --force --sign - --options runtime "$app"
"$app/Contents/MacOS/LibraryCheck" "$@"
