#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if xcodebuild -version >/dev/null 2>&1; then
    exec ./Scripts/swift-command.sh test "$@"
fi
./Scripts/swift-command.sh build
binary_dir="$(./Scripts/swift-command.sh build --show-bin-path)"
mkdir -p build
python3 - <<'PY'
from pathlib import Path
import re
lines = ['import Foundation', '@main struct TestRunner { static func main() {']
for path in sorted(Path('Tests/RecorderCoreTests').glob('*.swift')):
    text = path.read_text()
    cls = re.search(r'class (\w+): XCTestCase', text).group(1)
    for method, throwing in re.findall(r'func (test\w+)\(\)(\s+throws)?', text):
        prefix = 'try ' if throwing else ''
        lines.append(f'do {{ let t = {cls}(); StandaloneTests.run("{cls}.{method}", test: t) {{ {prefix}t.{method}() }} }}')
lines += ['print("Tests: \\(StandaloneTests.count), failures: \\(StandaloneTests.failures)")', 'exit(StandaloneTests.failures == 0 ? 0 : 1)', '} }']
Path('build/TestRunner.swift').write_text('\n'.join(lines))
PY
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx14.2" \
    -module-cache-path "$PWD/.build/module-cache" -I "$binary_dir/Modules" \
    -I Sources/CaptureBridge/include -framework CoreAudio -framework AVFoundation -lsqlite3 \
    Scripts/StandaloneTestSupport.swift Tests/RecorderCoreTests/*.swift build/TestRunner.swift \
    "$binary_dir"/RecorderCore.build/*.swift.o "$binary_dir"/Lookback.build/*.swift.o "$binary_dir"/CaptureBridge.build/CaptureBridge.c.o \
    -o build/RecorderCoreTests
export AFTERWORD_TEST_MCP="${AFTERWORD_TEST_MCP:-$binary_dir/AfterwordMCP}"
exec build/RecorderCoreTests
