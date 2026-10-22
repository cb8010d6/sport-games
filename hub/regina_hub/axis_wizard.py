"""Work out how the IMU chip is mounted from two still poses, and write regina_axis_map.

    python -m regina_hub.axis_wizard          (hub running, game closed)

Pose 1: lying flat, screen up      -> the chip axis that reads +1 g is canonical +Y (up).
Pose 2: standing on its end, tip up -> the chip axis that reads +1 g is canonical -Z (forward).
Canonical +X (right) = Y x Z. A pair of poses always yields a proper rotation, never a mirror.
"""

from __future__ import annotations

import argparse
import json
import math
import socket
import sys
import time
from pathlib import Path

from . import protocol as P
from .frames import handedness, make_remap

AXES = "xyz"


def _axis_name(index: int, sign: float) -> str:
    return ("-" if sign < 0 else "") + AXES[index]


def _invert(axis_map: list[str]):
    """canonical vector -> raw chip vector, for the map the hub is currently using."""
    remap_unit = [make_remap(axis_map)(tuple(1.0 if j == i else 0.0 for j in range(3))) for i in range(3)]

    def inv(v):
        # canonical = M @ raw with M orthonormal (columns = remap of chip unit axes) -> raw = M^T @ canonical
        return tuple(sum(remap_unit[i][k] * v[k] for k in range(3)) for i in range(3))

    return inv


class Listener:
    def __init__(self, game_port: int, hub_port: int):
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            self.sock.bind(("127.0.0.1", game_port))
        except OSError:
            sys.exit(f"UDP {game_port} 被占用——请先关掉 Godot 游戏再运行。")
        self.sock.settimeout(0.2)
        self.hub = ("127.0.0.1", hub_port)
        self.roster: dict = {}
        self._last_hello = 0.0

    def poll(self, seconds: float, on_sample=None) -> None:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if time.monotonic() - self._last_hello > 2.0:
                self.sock.sendto(b'{"cmd":"hello"}', self.hub)
                self._last_hello = time.monotonic()
            try:
                data, _ = self.sock.recvfrom(65536)
            except TimeoutError:
                continue
            except OSError:
                continue
            if data[:1] == b"{":
                msg = json.loads(data)
                if msg.get("type") == "roster":
                    self.roster = msg
            elif data[:1] == b"S" and on_sample is not None:
                cid, samples = P.parse_game_samples(data)
                for s in samples:
                    on_sample(cid, s)


def capture_gravity(listener: Listener, cid: int, seconds: float = 1.5) -> tuple[float, float, float]:
    """Mean body-frame accel over a still window (retries until the controller holds still)."""
    while True:
        acc: list[tuple[float, float, float]] = []
        gyro_max = [0.0]

        def on_sample(c, s, acc=acc, gyro_max=gyro_max):
            if c == cid:
                acc.append(s[8:11])
                gyro_max[0] = max(gyro_max[0], math.sqrt(s[5] ** 2 + s[6] ** 2 + s[7] ** 2))

        listener.poll(seconds, on_sample)
        if len(acc) < 5:
            sys.exit("收不到手柄数据——它还连着吗？")
        mean = tuple(sum(a[i] for a in acc) / len(acc) for i in range(3))
        norm = math.sqrt(sum(v * v for v in mean))
        if gyro_max[0] < 0.25 and abs(norm - 9.81) < 1.2:
            return mean
        print("  ……请保持静止", flush=True)


def dominant(v) -> tuple[int, float, float]:
    i = max(range(3), key=lambda k: abs(v[k]))
    return i, math.copysign(1.0, v[i]), abs(v[i]) / math.sqrt(sum(x * x for x in v))


def solve(up_raw, fwd_raw) -> tuple[list[str], float]:
    """Chip-frame gravity in pose 1 (screen up) and pose 2 (tip up) -> (axis map, alignment quality)."""
    yi, ys, yq = dominant(up_raw)
    fi, fs, fq = dominant(fwd_raw)
    if yi == fi:
        raise ValueError("两次姿势测到的是同一个轴——第 2 步要把手柄竖起来。请重试。")
    ey = [0.0] * 3
    ey[yi] = ys                 # canonical +Y = up
    ez = [0.0] * 3
    ez[fi] = -fs                # canonical +Z = backwards = -(tip)
    ex = [ey[1] * ez[2] - ey[2] * ez[1], ey[2] * ez[0] - ey[0] * ez[2], ey[0] * ez[1] - ey[1] * ez[0]]
    xi = max(range(3), key=lambda k: abs(ex[k]))
    new_map = [_axis_name(xi, ex[xi]), _axis_name(yi, ys), _axis_name(fi, -fs)]
    assert handedness(new_map) > 0
    return new_map, min(yq, fq)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(Path(__file__).resolve().parent.parent / "config.json"))
    ap.add_argument("--controller", type=int, default=0, help="controller id (default: first Regina)")
    ap.add_argument("--game-port", type=int, default=P.GAME_PORT)
    ap.add_argument("--hub-port", type=int, default=P.HUB_PORT)
    args = ap.parse_args()

    cfg_path = Path(args.config)
    cfg = json.loads(cfg_path.read_text(encoding="utf-8")) if cfg_path.exists() else {}
    current = list(cfg.get("regina_axis_map", ["x", "z", "-y"]))
    to_raw = _invert(current)

    listener = Listener(args.game_port, args.hub_port)
    print("正在连接 hub...", flush=True)
    listener.poll(2.5)
    live = [c for c in listener.roster.get("controllers", []) if c.get("connected")]
    if args.controller:
        live = [c for c in live if c["id"] == args.controller]
    else:
        live = [c for c in live if c.get("kind") == "regina"]
    if not live:
        sys.exit("没找到已连接的 Regina：请先运行 hub/run_hub.bat 并打开 Regina。")
    ctl = live[0]
    print(f"使用手柄 #{ctl['id']}：{ctl['name']}\n")

    input("第 1 步：把 Regina 屏幕朝上平放在桌面，按回车，然后别碰它... ")
    up_raw = to_raw(capture_gravity(listener, ctl["id"]))
    input("第 2 步：把 Regina 竖起来，让你平时握着它时朝前指的那一端朝上（屏幕朝向你），扶稳后按回车... ")
    fwd_raw = to_raw(capture_gravity(listener, ctl["id"]))

    try:
        new_map, quality = solve(up_raw, fwd_raw)
    except ValueError as exc:
        sys.exit(str(exc))
    if quality < 0.9:
        print(f"提示：姿势不太正（对齐度 {quality:.2f}），结果大概率仍然正确。")
    yi, ys, _ = dominant(up_raw)
    fi, fs, _ = dominant(fwd_raw)
    print(f"\n芯片轴向：屏幕朝外 = {_axis_name(yi, ys)}，前端 = {_axis_name(fi, fs)}")
    print(f"regina_axis_map: {current}  ->  {new_map}")
    if new_map == current:
        print("当前配置已经正确，无需修改。")
        return
    cfg["regina_axis_map"] = new_map
    cfg_path.write_text(json.dumps(cfg, indent=2) + "\n", encoding="utf-8")
    print(f"已写入 {cfg_path}，重启 hub 后生效。")


if __name__ == "__main__":
    main()
