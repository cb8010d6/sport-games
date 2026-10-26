"""Bootstrap main imports only from a successful same-repository dev PR with identical tree."""
import json
import os
import subprocess
from pathlib import Path


def gh_json(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", endpoint], text=True))


def find_run():
    if os.environ["GITHUB_REF"] != "refs/heads/main":
        return ""
    parents = subprocess.check_output(["git", "show", "-s", "--format=%P", "HEAD"], text=True).split()
    if len(parents) != 2:
        return ""
    source = parents[1]
    trees = [subprocess.check_output(["git", "rev-parse", ref + "^{tree}"], text=True).strip()
             for ref in ["HEAD", source]]
    if trees[0] != trees[1]:
        return ""
    repo = os.environ["GITHUB_REPOSITORY"]
    runs = gh_json(f"repos/{repo}/actions/workflows/windows-release.yml/runs?head_sha={source}&event=pull_request&status=success&per_page=10")
    for run in runs["workflow_runs"]:
        if (run["head_sha"] != source or run["head_branch"] != "dev"
                or (run.get("head_repository") or {}).get("full_name") != repo
                or run.get("event") != "pull_request" or run.get("conclusion") != "success"):
            continue
        artifacts = gh_json(f"repos/{repo}/actions/runs/{run['id']}/artifacts")
        if any(a["name"] == "Godot-imports" and not a["expired"] for a in artifacts["artifacts"]):
            return str(run["id"])
    return ""


if __name__ == "__main__":
    run_id = find_run()
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write("run_id=" + run_id + "\n")
    print("Verified import artifact run:", run_id or "none; use normal import")
