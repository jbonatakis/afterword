#!/usr/bin/env python3
"""Verify update identity compatibility without launching either application."""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def run(*args, check=True):
    return subprocess.run(args, text=True, capture_output=True, check=check)


def signature(path):
    run("codesign", "--verify", "--deep", "--strict", str(path))
    details = run("codesign", "--display", "--verbose=4", str(path)).stderr
    if "Signature=adhoc" in details:
        raise RuntimeError(f"{path} still uses ad-hoc signing")
    requirement = run("codesign", "--display", "-r-", str(path)).stdout
    match = re.search(r"^designated => (.+)$", requirement, re.MULTILINE)
    digest = re.search(r"^CDHash=(.+)$", details, re.MULTILINE)
    if not match or not digest or ("certificate" not in match[1] and "anchor" not in match[1]):
        raise RuntimeError(f"{path} does not have a certificate-bound designated requirement")
    return match[1], digest[1]


def verify_updates(previous, updated):
    old_requirement, old_hash = signature(previous)
    new_requirement, new_hash = signature(updated)
    run("codesign", "--verify", "--strict", "-R=" + old_requirement, str(updated))
    run("codesign", "--verify", "--strict", "-R=" + new_requirement, str(previous))
    if old_requirement != new_requirement:
        raise RuntimeError("The designated requirements changed between builds")
    if old_hash == new_hash:
        raise RuntimeError("The app builds are identical; use two different builds to verify update identity")

    helper_path = Path("Contents/Helpers/TranscriptionWorker")
    old_helper, _ = signature(previous / helper_path)
    new_helper, _ = signature(updated / helper_path)
    if old_helper != new_helper or new_helper == new_requirement:
        raise RuntimeError("The helper must have a stable identity distinct from its parent app")
    run("codesign", "--verify", "--strict", "-R=" + old_helper, str(updated / helper_path))

    with tempfile.TemporaryDirectory(prefix="call-recorder-signing-check-") as temporary:
        impostor = Path(temporary) / "Same Identifier.app"
        shutil.copytree(updated, impostor, symlinks=True)
        run("codesign", "--force", "--sign", "-", "--preserve-metadata=identifier,entitlements,flags", str(impostor))
        if run("codesign", "--verify", "--strict", "-R=" + new_requirement, str(impostor), check=False).returncode == 0:
            raise RuntimeError("An ad-hoc copy with the same bundle ID unexpectedly satisfies the certificate identity")
    print("PASS different app hashes, identical certificate-bound identities, mutual update compatibility, stable helper identity, and rejection of an ad-hoc copy with the same bundle ID.")
    print("No apps launched, privacy permissions requested, or TCC records modified.")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: Scripts/check-signing.py PREVIOUS_SIGNED_APP UPDATED_SIGNED_APP")
    try:
        verify_updates(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"FAIL: {error}\n{getattr(error, 'stderr', '')}")
