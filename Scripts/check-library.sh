#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/swift-command.sh build
binary_dir="$(./Scripts/swift-command.sh build --show-bin-path)"
app="$PWD/build/Library Check.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.local.callrecorder.librarycheck</string>
<key>CFBundleExecutable</key><string>LibraryCheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    -module-cache-path "$PWD/.build/module-cache" -I "$binary_dir/Modules" \
    -I Sources/CaptureBridge/include -framework CoreAudio -framework AVFoundation -lsqlite3 -framework Carbon -framework IOKit -framework EventKit \
    "${1:-Tests/LibraryHarness.swift}" Sources/CallRecorder/RecordingLibraryModel.swift Sources/CallRecorder/RecordingLibraryView.swift Sources/CallRecorder/RecordingLibraryWindow.swift Sources/CallRecorder/LibraryKeyboard.swift Sources/CallRecorder/CallEditors.swift Sources/CallRecorder/AttendanceEditor.swift Sources/CallRecorder/CalendarCoordinator.swift Sources/CallRecorder/CalendarViews.swift \
    Sources/CallRecorder/RecordingCoordinator.swift Sources/CallRecorder/RecordingShortcut.swift Sources/CallRecorder/TranscriptionCoordinator.swift \
    "$binary_dir"/RecorderCore.build/*.swift.o "$binary_dir"/CaptureBridge.build/CaptureBridge.c.o \
    "$binary_dir"/KeyboardShortcuts.build/*.swift.o -o "$app/Contents/MacOS/LibraryCheck"
cp -R "$binary_dir/KeyboardShortcuts_KeyboardShortcuts.bundle" "$app/Contents/Resources/"
codesign --force --sign - --options runtime "$app"
exec "$app/Contents/MacOS/LibraryCheck"
