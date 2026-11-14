#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
action="${1:-build}"
if [ "$#" -gt 0 ]; then shift; fi
exec swift "$action" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security -Xswiftc -module-cache-path -Xswiftc "$PWD/.build/module-cache" "$@"
