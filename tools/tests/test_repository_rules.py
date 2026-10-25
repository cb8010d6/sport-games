"""Branch rulesets: both main and dev are applied, and every required check is one CI actually reports."""
import json
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path

from tools.apply_repository_rules import RULESETS, apply, reviewed_rulesets

WORKFLOWS = RULESETS.parent / "workflows"


def required_checks(ruleset):
    rule = next(r for r in ruleset["rules"] if r["type"] == "required_status_checks")
    return [check["context"] for check in rule["parameters"]["required_status_checks"]]


def load(name):
    return json.loads((RULESETS / name).read_text(encoding="utf-8"))


class CheckedInRulesetsTest(unittest.TestCase):
    def test_main_and_dev_are_both_applied(self):
        targets = {}
        for file in reviewed_rulesets():
            ruleset = json.loads(file.read_text(encoding="utf-8"))
            for ref in ruleset["conditions"]["ref_name"]["include"]:
                targets[ref] = file.name
        self.assertEqual(targets, {"refs/heads/main": "main.json", "refs/heads/dev": "dev.json"})

    def test_dev_needs_a_pull_request_and_cannot_be_rewritten(self):
        types = {rule["type"] for rule in load("dev.json")["rules"]}
        self.assertLessEqual({"deletion", "non_fast_forward", "pull_request", "required_status_checks"}, types)
        checks = required_checks(load("dev.json"))
        for check in ["hub (ubuntu-latest, 3.11)", "hub (ubuntu-latest, 3.12)", "hub (windows-latest, 3.12)", "privacy", "game-shell"]:
            self.assertIn(check, checks)

    def test_main_requires_everything_dev_requires_plus_the_windows_tool_tests(self):
        main = required_checks(load("main.json"))
        self.assertLessEqual(set(required_checks(load("dev.json"))), set(main))
        for check in ["game-shell", "engine-runner (ubuntu-latest)", "engine-runner (windows-latest)"]:
            self.assertIn(check, main)

    def test_every_required_check_is_a_reported_job(self):
        jobs = {}
        for workflow in WORKFLOWS.glob("*.yml"):
            text = workflow.read_text(encoding="utf-8")
            body = text[text.index("\njobs:\n"):]
            for job in re.findall(r"^  ([A-Za-z0-9_-]+):\s*$", body, re.MULTILINE):
                jobs[job] = text
        for ruleset in ["main.json", "dev.json"]:
            for check in required_checks(load(ruleset)):
                match = re.fullmatch(r"([A-Za-z0-9_-]+)(?: \((.+)\))?", check)
                self.assertIsNotNone(match, check)
                self.assertIn(match.group(1), jobs, f"{ruleset}: no CI job reports {check!r}")
                for value in (match.group(2) or "").split(", "):
                    self.assertIn(value, jobs[match.group(1)], f"{ruleset}: matrix value of {check!r} not in workflow")


class ApplyTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.folder = Path(temporary.name)
        self.ruleset = {"name": "Protect dev", "conditions": {"ref_name": {"include": ["refs/heads/dev"]}}, "rules": [{"type": "deletion"}]}
        self.file = self.folder / "dev.json"
        self.file.write_text(json.dumps(self.ruleset), encoding="utf-8")

    def fake_api(self, returned):
        calls = []

        def api(*args):
            calls.append(args)
            return {"id": 7} if args[0] == "--method" else returned

        return api, calls

    def test_new_ruleset_is_created_then_verified(self):
        api, calls = self.fake_api({**self.ruleset, "id": 7, "enforcement": "active"})
        with redirect_stdout(StringIO()) as output:
            apply(self.file, [{"name": "Protect stable main", "id": 1}], api)
        self.assertEqual(calls[0][:3], ("--method", "POST", "repos/cb8010d6/sport-games/rulesets"))
        self.assertEqual(calls[1], ("repos/cb8010d6/sport-games/rulesets/7",))
        self.assertIn("applied to dev", output.getvalue())

    def test_existing_ruleset_is_updated_in_place(self):
        api, calls = self.fake_api(self.ruleset)
        with redirect_stdout(StringIO()):
            apply(self.file, [{"name": "Protect dev", "id": 5}], api)
        self.assertEqual(calls[0][:3], ("--method", "PUT", "repos/cb8010d6/sport-games/rulesets/5"))

    def test_mismatch_after_applying_fails(self):
        api, _ = self.fake_api({**self.ruleset, "rules": []})
        with self.assertRaises(SystemExit):
            apply(self.file, [], api)

    def test_duplicate_names_are_rejected(self):
        (self.folder / "copy.json").write_text(json.dumps(self.ruleset), encoding="utf-8")
        with self.assertRaises(SystemExit):
            reviewed_rulesets(self.folder)


if __name__ == "__main__":
    unittest.main()
