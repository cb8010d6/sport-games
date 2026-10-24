"""regina-hub entry point: python -m regina_hub [options]"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import ipaddress
import json
import logging
import sys
from collections.abc import Awaitable, Callable
from pathlib import Path
from typing import Any

from . import protocol as P
from .frames import PHONE_AXIS_MAP, REGINA_DEFAULT_AXIS_MAP, handedness
from .hub import Hub
from .netutil import ensure_cert, lan_ips, qr_rows, ssl_context
from .recorder import Recorder, replay
from .sources.web import WebSource

HUB_DIR = Path(sys.executable).resolve().parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent.parent
DEFAULT_CONFIG = HUB_DIR / "config.json"
log = logging.getLogger("main")
SOURCE_RETRY_INITIAL_S = 1.0
SOURCE_RETRY_MAX_S = 30.0


def load_config(path: Path) -> dict[str, Any]:
    cfg: dict[str, Any] = {
        "regina_axis_map": list(REGINA_DEFAULT_AXIS_MAP),
        "phone_axis_map": list(PHONE_AXIS_MAP),
        "regina_allow": [],
        "regina_name_prefix": P.DEVICE_NAME_PREFIX,
        "regina_screen_rotation": 3,
        "https_host": "0.0.0.0",
    }
    if path.exists():
        cfg.update(json.loads(path.read_text(encoding="utf-8")))
    for key in ("regina_axis_map", "phone_axis_map"):
        if handedness(cfg[key]) < 0:
            raise SystemExit(f"{key} {cfg[key]} is a mirror image (left-handed); flip the sign of one axis")
    return cfg


def parse_args(argv: list[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="regina_hub", description="Regina Sports controller hub")
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--data-dir", type=Path, default=HUB_DIR, help="directory for locally generated certificates")
    ap.add_argument("--no-ble", action="store_true", help="don't scan for Regina controllers")
    ap.add_argument("--no-https", action="store_true", help="don't serve the phone controller page")
    ap.add_argument("--record", type=Path, help="append raw controller data to this JSONL file")
    ap.add_argument("--replay", type=Path, help="replay a recording as a virtual controller")
    ap.add_argument("--game-port", type=int, default=P.GAME_PORT)
    ap.add_argument("--hub-port", type=int, default=P.HUB_PORT)
    ap.add_argument("--http-port", type=int, default=P.HTTP_PORT)
    ap.add_argument("--https-port", type=int, default=P.HTTPS_PORT)
    ap.add_argument("--https-host", help="interface address for the phone HTTPS listener (default: all interfaces)")
    ap.add_argument("--lan-ip", help="address phones should use (default: auto-detected)")
    ap.add_argument("-v", "--verbose", action="store_true")
    return ap.parse_args(argv)


async def _run_optional_source(name: str, run: Callable[[], Awaitable[None]], *, retry: bool = False) -> None:
    """Keep optional device/replay failures out of the core hub task."""
    delay = SOURCE_RETRY_INITIAL_S
    while True:
        try:
            await run()
            return
        except ImportError:
            log.warning("%s source disabled: dependency unavailable; other sources remain available", name)
            return
        except Exception as exc:  # source boundary: core failures still propagate
            # Do not log source payloads, device identifiers or recording contents.
            if not retry:
                log.warning("%s source stopped (%s); other sources remain available", name, type(exc).__name__)
                return
            log.warning("%s source failed (%s); retrying in %.1f s", name, type(exc).__name__, delay)
        await asyncio.sleep(delay)
        delay = min(delay * 2, SOURCE_RETRY_MAX_S)


async def _run_ble(hub: Hub, cfg: dict[str, Any]) -> None:
    from .sources.ble import ReginaBleSource

    ble = ReginaBleSource(hub, cfg["regina_axis_map"], cfg["regina_name_prefix"], cfg["regina_allow"], cfg["regina_screen_rotation"])
    await ble.run()


async def _run_replay(hub: Hub, path: Path) -> None:
    try:
        await replay(hub, path)
    finally:
        # A failed/cancelled replay must release any player slots it already attached.
        for c in list(hub.controllers.values()):
            if c.kind == "replay" and c.connected:
                hub.detach(c)


async def amain(args: argparse.Namespace) -> None:
    cfg = load_config(args.config)
    recorder = Recorder(args.record) if args.record else None
    hub = Hub(game_port=args.game_port, hub_port=args.hub_port, recorder=recorder)
    await hub.start()

    web = WebSource(hub, phone_axis_map=cfg["phone_axis_map"])
    tasks: list[asyncio.Task[None]] = []
    try:
        ssl_ctx = None
        if not args.no_https:
            ips = lan_ips()
            https_host = args.https_host or cfg["https_host"]
            selected_interface = ipaddress.ip_address(https_host)
            ip = args.lan_ip or cfg.get("lan_ip") or (str(selected_interface) if not selected_interface.is_unspecified else ips[0])
            cert, key = ensure_cert(args.data_dir / ".certs", [ip])
            ssl_ctx = ssl_context(cert, key)
            url_host = f"[{ip}]" if ":" in ip else ip
            hub.phone_url = f"https://{url_host}:{args.https_port}/#k={web.pairing_token}"
            hub.qr = {"type": "qr", "url": hub.phone_url, "rows": qr_rows(hub.phone_url)}
        await web.start("127.0.0.1", args.http_port, None if args.no_https else args.https_port, ssl_ctx,
                        https_host=args.https_host or cfg["https_host"])

        tasks.append(asyncio.create_task(hub.run_forever(), name="hub"))
        if not args.no_ble:
            tasks.append(asyncio.create_task(_run_optional_source("BLE", lambda: _run_ble(hub, cfg), retry=True), name="ble"))
        if args.replay:
            # A corrupt replay is stopped, not retried from its beginning (which duplicates input).
            tasks.append(asyncio.create_task(_run_optional_source("replay", lambda: _run_replay(hub, args.replay)), name="replay"))

        print()
        print("  Regina Sports hub is running")
        print(f"  Simulator:   http://127.0.0.1:{args.http_port}/sim")
        if hub.phone_url:
            print(f"  Phone:       {hub.phone_url.split('#', 1)[0]}   (scan the in-game QR code to pair)")
            others = [i for i in ips if i != ip]
            if others:
                print(f"  Wrong network? Other addresses: {', '.join(others)}  (use --lan-ip)")
        print()

        await asyncio.gather(*tasks)
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await web.stop()
        hub.close()
        if recorder is not None:
            recorder.close()


def main(argv: list[str] | None = None) -> None:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(name)-5s %(message)s", datefmt="%H:%M:%S")
    logging.getLogger("bleak").setLevel(logging.INFO)
    logging.getLogger("asyncio").setLevel(logging.WARNING)
    if sys.platform == "win32":
        with contextlib.suppress(AttributeError):
            sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    with contextlib.suppress(KeyboardInterrupt):
        asyncio.run(amain(args))


if __name__ == "__main__":
    main()
