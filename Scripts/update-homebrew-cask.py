"""Update the tap's Afterword cask from a GitHub release API response."""
import json
from pathlib import Path
import re
import sys


def update(release, cask):
    version_pattern = r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}"
    tag = release["tag_name"]
    if release["draft"] or release["prerelease"] or not re.fullmatch(f"v{version_pattern}", tag):
        raise ValueError(f"Expected a published stable Afterword release, got {tag!r}")

    text = cask.read_text()
    entry = re.compile(rf'^  version "({version_pattern})"\n  sha256 "[0-9a-f]{{64}}"$', re.MULTILINE)
    current, = entry.findall(text)
    version = tag[1:]
    if tuple(map(int, current.split("."))) > tuple(map(int, version.split("."))):
        print(f"Keeping newer Afterword cask {current}.")
        return

    filename = f"Afterword-{tag}-macOS-arm64.zip"
    asset, = [a for a in release["assets"] if a["name"] == filename and a["state"] == "uploaded"]
    digest = re.fullmatch(r"sha256:([0-9a-f]{64})", asset.get("digest") or "")
    if not digest:
        raise ValueError(f"Missing SHA-256 for {filename}")
    cask.write_text(entry.sub(f'  version "{version}"\n  sha256 "{digest[1]}"', text))


if __name__ == "__main__":
    release_path, cask_path = map(Path, sys.argv[1:])
    update(json.loads(release_path.read_text()), cask_path)
