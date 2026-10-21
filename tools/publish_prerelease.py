"""Publish a checked CI package; an existing release is never replaced."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
config = json.loads((ROOT / "tools/release_config.json").read_text())
repo = os.environ["GITHUB_REPOSITORY"]
ref = os.environ["GITHUB_REF"]
commit = os.environ["GITHUB_SHA"]
tagged = ref.startswith("refs/tags/")
if not tagged and ref != "refs/heads/main":
    raise SystemExit("Only main or a version tag may publish a release")
tag = ref.removeprefix("refs/tags/") if tagged else config["initialPrerelease"]
if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", tag):
    raise SystemExit("Invalid release version")
subprocess.run(["git", "merge-base", "--is-ancestor", commit, "origin/main"], check=True)
existing = json.loads(subprocess.check_output(
    ["gh", "release", "list", "--repo", repo, "--limit", "1000", "--json", "tagName"], text=True))
if any(item["tagName"] == tag for item in existing):
    print("Release already exists; keeping it unchanged:", tag)
    raise SystemExit(0)
archive = ROOT / "release" / (config["packageName"] + ".zip")
checksum = archive.with_suffix(".zip.sha256")
with archive.open("rb") as stream:
    actual = hashlib.file_digest(stream, "sha256").hexdigest()
if checksum.read_text().split() != [actual, archive.name]:
    raise SystemExit("Release archive checksum does not match")
command = ["gh", "release", "create", tag, str(archive), str(checksum), "--repo", repo,
           "--title", "Sport Games " + tag, "--generate-notes", "--prerelease"]
command += ["--verify-tag"] if tagged else ["--target", commit]
subprocess.run(command, check=True)
