"""Maintain the rolling Afterword draft for main. Run from a full checkout of main."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

START = "<!-- afterword:changes -->"
END = "<!-- /afterword:changes -->"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def version(value):
    match = VERSION.fullmatch(value)
    if not match:
        raise ValueError(f"Expected a major.minor.patch version, got {value!r}")
    return tuple(map(int, match.groups()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    repo = os.environ["GITHUB_REPOSITORY"]
    endpoint = f"repos/{repo}/releases"
    pages = json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp", endpoint]))
    releases = [release for page in pages for release in page]
    drafts = [r for r in releases if r["draft"] and START in (r["body"] or "")]
    if len(drafts) > 1:
        raise SystemExit("Found multiple managed Afterword drafts. Keep one before retrying.")
    draft = next(iter(drafts), None)

    head = git("rev-parse", "HEAD")
    merged = set(git("tag", "--merged", head).splitlines())
    published = [r["tag_name"] for r in releases if not r["draft"] and not r["prerelease"]
                 and r["tag_name"] in merged and r["tag_name"].startswith("v") and VERSION.fullmatch(r["tag_name"][1:])]
    previous = max(published, key=lambda tag: version(tag[1:]), default=None)
    planned = version(plistlib.loads(Path("Configuration/Info.plist").read_bytes())["CFBundleShortVersionString"])
    if previous:
        if git("rev-parse", f"{previous}^{{commit}}") == head:
            print(f"{previous} already includes this commit.")
            return
        major, minor, patch = version(previous[1:])
        planned = max(planned, (major, minor, patch + 1))
    tag = "v" + ".".join(map(str, planned))
    if git("tag", "--list", tag) or any(r["tag_name"] == tag and r != draft for r in releases):
        raise SystemExit(f"{tag} is already in use. Choose a higher app version before retrying.")

    commits = f"{previous}..{head}" if previous else head
    changes = git("log", "--no-merges", "--format=- %s (%h)", commits)
    section = f"{START}\n## Changes\n\n{changes}\n{END}"
    if draft:
        before, _, old = draft["body"].partition(START)
        _, marker, after = old.partition(END)
        if not marker:
            raise SystemExit("The draft is missing the end of its generated notes section.")
        body = before + section + after
    else:
        body = section
    payload = {"tag_name": tag, "target_commitish": head, "name": f"Afterword {tag}", "body": body}
    if args.dry_run:
        print(json.dumps(payload, indent=2))
        return
    if draft:
        endpoint += f"/{draft['id']}"
        method = "PATCH"
    else:
        payload["draft"] = True
        method = "POST"
    subprocess.run(["gh", "api", "--method", method, endpoint, "--input", "-", "--jq", ".html_url"],
                   input=json.dumps(payload), text=True, check=True)


if __name__ == "__main__":
    main()
