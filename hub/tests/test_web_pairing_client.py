"""Run the browser pairing contract tests in the regular hub CI suite."""

import shutil
import subprocess
from pathlib import Path


def test_browser_pairing_contract():
    node = shutil.which("node")
    assert node is not None, "Node is required for the browser pairing contract tests"
    test_file = Path(__file__).with_suffix(".mjs")
    result = subprocess.run([node, "--test", str(test_file)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
