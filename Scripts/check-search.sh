#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/swift-command.sh build -c release
binary_dir="$(./Scripts/swift-command.sh build -c release --show-bin-path)"
mkdir -p build
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    -module-cache-path "$PWD/.build/module-cache" -I "$binary_dir/Modules" \
    -I Sources/CaptureBridge/include -framework CoreAudio -framework AVFoundation -lsqlite3 \
    Tests/SearchBenchmark.swift "$binary_dir"/RecorderCore.build/*.swift.o "$binary_dir"/Lookback.build/*.swift.o \
    "$binary_dir"/CaptureBridge.build/CaptureBridge.c.o -o build/SearchBenchmark
exec build/SearchBenchmark
