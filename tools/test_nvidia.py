"""Check optional fork APIs and standard-engine fallback without a GPU or player saves."""
from __future__ import annotations

import argparse
from pathlib import Path

from smoke_game import checked_run
from test_game import ROOT, find_godot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot")
    parser.add_argument("--output", type=Path, default=ROOT / "audit-output/nvidia-cpu")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    output = checked_run([find_godot(args.godot), "--headless", "--path", str(ROOT / "game"),
                          "res://tests/test_nvidia.tscn"], timeout=120)
    (args.output / "checks.log").write_text(output, encoding="utf-8")
    markers = [line for line in output.splitlines() if line.startswith("RS_NVIDIA:")]
    if len(markers) != 1 or not markers[0].endswith(", 0 failures"):
        raise RuntimeError("Missing NVIDIA CPU regression success marker")
    print(markers[0])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
