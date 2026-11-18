#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
./Scripts/swift-command.sh build --target RecorderCore >/dev/null
bin="$(./Scripts/swift-command.sh build --show-bin-path)"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
  -module-cache-path "$PWD/.build/module-cache" -I "$bin/Modules" -I Sources/CaptureBridge/include \
  Tests/SearchQuality/Import.swift "$bin"/RecorderCore.build/*.swift.o "$bin"/Lookback.build/*.swift.o \
  "$bin"/CaptureBridge.build/CaptureBridge.c.o -framework CoreAudio -framework AVFoundation -lsqlite3 \
  -o "$2/import-fixtures"
"$2/import-fixtures" "$1" "$2"
