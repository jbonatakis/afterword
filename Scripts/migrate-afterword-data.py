#!/usr/bin/env python3
"""One-time local rename migration. Run with the app and MCP helpers stopped."""
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

LEGACY_DOMAIN = "io.local.callrecorder"
DOMAIN = "io.local.afterword"


def read_preferences(domain):
    result = subprocess.run(["defaults", "export", domain, "-"], capture_output=True)
    if result.returncode:
        if b"does not exist" in result.stderr:
            return {}
        raise RuntimeError(result.stderr.decode(errors="replace"))
    return plistlib.loads(result.stdout)


def write_preferences(domain, values):
    with tempfile.NamedTemporaryFile(suffix=".plist") as file:
        file.write(plistlib.dumps(values))
        file.flush()
        subprocess.run(["defaults", "import", domain, file.name], check=True, capture_output=True)


def move_directories(pairs):
    # Preflight every destination before moving anything. Never merge model,
    # session, or SQLite files from independently used installations.
    moves = []
    for source, destination in pairs:
        if source.is_symlink() or destination.is_symlink():
            raise RuntimeError("Refusing to migrate a symbolic-link data directory")
        if not source.exists():
            continue
        if destination.exists():
            raise RuntimeError(f"Both {source} and {destination} exist; leaving both untouched")
        if not source.is_dir():
            raise RuntimeError(f"Expected a data directory at {source}")
        moves.append((source, destination))
    completed = []
    try:
        for source, destination in moves:
            source.rename(destination)
            completed.append((source, destination))
    except BaseException:
        for source, destination in reversed(completed):
            destination.rename(source)
        raise
    return completed


def main():
    processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True)
    names = {"CallRecorder", "Afterword", "CallRecorderMCP", "AfterwordMCP"}
    for line in processes.splitlines():
        pid, executable = line.strip().split(None, 1)
        owned_worker = ("/call-recorder/" in executable or "/afterword/" in executable) and Path(executable).name in {"EmbeddingWorker", "TranscriptionWorker"}
        if Path(executable).name in names or owned_worker:
            raise RuntimeError(f"Close the recorder and MCP processes before migrating (PID {pid})")
    home = Path.home()
    pairs = [(home / "Library" / folder / "Call Recorder", home / "Library" / folder / "Afterword")
             for folder in ("Application Support", "Caches")]
    legacy = read_preferences(LEGACY_DOMAIN)
    current = read_preferences(DOMAIN)
    merged = {key.replace("CallRecorderStatusItem", "AfterwordStatusItem"): value for key, value in legacy.items()}
    merged.update(current)
    completed = move_directories(pairs)
    try:
        if merged != current:
            write_preferences(DOMAIN, merged)
    except BaseException:
        # Keep the original preference domain for rollback even on success.
        for source, destination in reversed(completed):
            destination.rename(source)
        raise
    print(f"Migrated {len(completed)} data directories; Afterword has {len(merged)} preference keys.")
    print("Original preferences retained for rollback. Recordings and macOS permissions were not modified.")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
