"""Record canonical-frame raw controller data to JSONL and replay it as a virtual controller.

Line formats:
  {"k":"imu","c":"<session>/<alias>","n":"<alias>","h":<hub time>,"s":[[device_us,gx,gy,gz,ax,ay,az],...]}
  {"k":"in","c":"<session>/<alias>","n":"<alias>","h":<hub time>,"b":3,"d":[0,0],"an":[0,0]}

Aliases are local to one Recorder, stable across reconnections, and omit device names/keys.
Replay also accepts the original key/name format. Existing recordings are not rewritten.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from pathlib import Path
from typing import Any, TextIO

from .controller import Controller, NullTransport
from .hub import Hub

log = logging.getLogger("rec")


class Recorder:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self._f: TextIO = path.open("a", encoding="utf-8")
        self._lines = 0
        self._session = uuid.uuid4().hex
        self._aliases: dict[str, str] = {}
        log.info("recording to %s", path)

    def _write(self, obj: dict[str, Any]) -> None:
        self._f.write(json.dumps(obj, separators=(",", ":")) + "\n")
        self._lines += 1
        if self._lines % 200 == 0:
            self._f.flush()

    def _identity(self, c: Controller) -> dict[str, str]:
        alias = self._aliases.get(c.key)
        if alias is None:
            kind = c.kind if c.kind in {"regina", "phone", "sim", "replay"} else "controller"
            alias = f"{kind}-{len(self._aliases) + 1}"
            self._aliases[c.key] = alias
        return {"c": f"{self._session}/{alias}", "n": alias}

    def imu(self, c: Controller, items: list[tuple[float, Any, Any]]) -> None:
        self._write(
            {
                "k": "imu",
                **self._identity(c),
                "h": round(time.monotonic(), 6),
                "s": [[round(t, 1), *(round(v, 6) for v in g), *(round(v, 5) for v in a)] for t, g, a in items],
            }
        )

    def input(self, c: Controller, buttons: int, small: int, big: int, analog: tuple[float, float]) -> None:
        self._write({"k": "in", **self._identity(c), "h": round(time.monotonic(), 6), "b": buttons, "d": [small, big], "an": list(analog)})

    def close(self) -> None:
        self._f.flush()
        self._f.close()


async def replay(hub: Hub, path: Path, loop_forever: bool = True, speed: float = 1.0) -> None:
    """Feed a recording back through the hub; each recorded controller becomes a 'replay' controller."""
    lines = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not lines:
        log.warning("recording %s is empty", path)
        return
    log.info("replaying %s (%d lines)", path, len(lines))
    while True:
        controllers: dict[str, Controller] = {}
        t0_rec = lines[0]["h"]
        t0 = time.monotonic()
        for rec in lines:
            delay = (rec["h"] - t0_rec) / speed - (time.monotonic() - t0)
            if delay > 0:
                await asyncio.sleep(delay)
            key = "replay:" + rec["c"]
            c = controllers.get(key)
            if c is None:
                c = hub.attach("replay", key, "REPLAY " + rec.get("n", "?"), NullTransport(), rate_hint_hz=200.0, wrap_bits=32)
                if c is None:
                    log.warning("replay: controller registry full, skipping %s", key)
                    continue
                controllers[key] = c
            if rec["k"] == "imu":
                items = [(s[0], (s[1], s[2], s[3]), (s[4], s[5], s[6])) for s in rec["s"]]
                hub.on_imu(c, items)
            elif rec["k"] == "in":
                hub.on_input(c, rec["b"], rec["d"][0], rec["d"][1], (rec["an"][0], rec["an"][1]))
        for c in controllers.values():
            hub.detach(c)
        if not loop_forever:
            return
        await asyncio.sleep(1.0)
