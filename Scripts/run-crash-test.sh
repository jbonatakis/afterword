#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/swift-command.sh build
binary_dir="$(./Scripts/swift-command.sh build --show-bin-path)"
mkdir -p build
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    -module-cache-path "$PWD/.build/module-cache" -I "$binary_dir/Modules" \
    -I Sources/CaptureBridge/include -framework CoreAudio -framework AVFoundation \
    Tests/CrashHarness.swift "$binary_dir"/RecorderCore.build/*.swift.o "$binary_dir"/Lookback.build/*.swift.o \
    "$binary_dir"/CaptureBridge.build/CaptureBridge.c.o -o build/CrashHarness
python3 - <<'PY'
from pathlib import Path
import subprocess, tempfile, time, signal
root = Path(tempfile.mkdtemp(prefix='crash-fixture-', dir='build')).resolve()
binary = Path('build/CrashHarness').resolve()
writer = subprocess.Popen([str(binary), 'write', str(root)])
try:
    deadline = time.monotonic() + 30
    while not (root / 'ready').exists():
        if writer.poll() is not None: raise RuntimeError('Fixture writer failed')
        if time.monotonic() > deadline: raise TimeoutError('Fixture writer timed out')
        time.sleep(0.05)
    writer.send_signal(signal.SIGKILL)
    writer.wait(timeout=5)
    subprocess.run([str(binary), 'recover', str(root)], check=True)
finally:
    if writer.poll() is None:
        writer.kill()
        writer.wait()
PY
