#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/Calendar Spike.app"
mkdir -p "$app/Contents/MacOS" "$PWD/build/calendar-spike" "$PWD/.build/module-cache"
chmod 700 "$PWD/build/calendar-spike"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.local.callrecorder.calendarspike</string>
<key>CFBundleName</key><string>Calendar Spike</string>
<key>CFBundleDisplayName</key><string>Calendar Spike</string>
<key>CFBundleExecutable</key><string>CalendarSpike</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSCalendarsFullAccessUsageDescription</key><string>Read your selected work calendar to check whether meeting links, attendee names, emails, and groups are available for Call Recorder. This probe does not change calendar events.</string>
</dict></plist>
PLIST
cat > "$PWD/build/calendar-spike/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.personal-information.calendars</key><true/>
</dict></plist>
PLIST
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    -module-cache-path "$PWD/.build/module-cache" -framework AppKit -framework EventKit \
    Tests/CalendarSpike.swift -o "$app/Contents/MacOS/CalendarSpike"
codesign --force --sign - --options runtime --entitlements "$PWD/build/calendar-spike/entitlements.plist" "$app"
codesign --verify --strict "$app"
open -n -W "$app" --args "$@"
