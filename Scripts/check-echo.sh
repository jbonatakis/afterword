#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-transcription.sh
exec build/native/echo/EchoTests
