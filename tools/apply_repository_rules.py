"""Apply the reviewed main ruleset with the maintainer's administrative GitHub CLI login."""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "cb8010d6/sport-games"


def contains(actual, expected):
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(key in actual and contains(actual[key], value) for key, value in expected.items())
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and all(any(contains(item, value) for item in actual) for value in expected)
    return actual == expected


def main():
    existing = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPO}/rulesets"], text=True))
    found = next((r for r in existing if r["name"] == "Protect stable main"), None)
    endpoint = f"repos/{REPO}/rulesets" + (f"/{found['id']}" if found else "")
    configured = json.loads(subprocess.check_output(["gh", "api", "--method", "PUT" if found else "POST", endpoint,
                    "--input", str(ROOT / ".github/rulesets/main.json")], text=True))
    verified = json.loads(subprocess.check_output(["gh", "api", f"repos/{REPO}/rulesets/{configured['id']}"], text=True))
    expected = json.loads((ROOT / ".github/rulesets/main.json").read_text())
    if not contains(verified, expected):
        raise SystemExit("GitHub returned a different ruleset; inspect repository settings.")
    print("Verified configuration applied to main.")


if __name__ == "__main__":
    main()
