"""Apply every reviewed ruleset in .github/rulesets with the maintainer's administrative GitHub CLI login."""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "cb8010d6/sport-games"
RULESETS = ROOT / ".github/rulesets"


def contains(actual, expected):
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(key in actual and contains(actual[key], value) for key, value in expected.items())
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and all(any(contains(item, value) for item in actual) for value in expected)
    return actual == expected


def gh_api(*args):
    return json.loads(subprocess.check_output(["gh", "api", *args], text=True))


def reviewed_rulesets(folder=RULESETS):
    """All checked-in rulesets (main.json, dev.json, ...); names must be unique because they are the update key."""
    files = sorted(folder.glob("*.json"))
    if not files:
        raise SystemExit(f"No rulesets found in {folder}")
    names = [json.loads(file.read_text(encoding="utf-8"))["name"] for file in files]
    if len(set(names)) != len(names):
        raise SystemExit("Ruleset names must be unique: " + ", ".join(names))
    return files


def apply(file, existing, api=gh_api):
    expected = json.loads(file.read_text(encoding="utf-8"))
    found = next((r for r in existing if r["name"] == expected["name"]), None)
    endpoint = f"repos/{REPO}/rulesets" + (f"/{found['id']}" if found else "")
    configured = api("--method", "PUT" if found else "POST", endpoint, "--input", str(file))
    verified = api(f"repos/{REPO}/rulesets/{configured['id']}")
    if not contains(verified, expected):
        raise SystemExit(f"GitHub returned a different ruleset for {file.name}; inspect repository settings.")
    targets = ", ".join(ref.removeprefix("refs/heads/") for ref in expected["conditions"]["ref_name"]["include"])
    print(f"Verified {expected['name']!r} applied to {targets}.")


def main():
    existing = gh_api(f"repos/{REPO}/rulesets")
    for file in reviewed_rulesets():
        apply(file, existing)


if __name__ == "__main__":
    main()
