"""检查两份 LAN 候选报告的完整性与一致性；不启动游戏或证明网络正确。

协议与生产者尚未实现，schema 使用 lan-report-draft-1。仅依赖标准库。
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Any

SCHEMA = "lan-report-draft-1"
MAX_BYTES = 1 << 20
U32 = (1 << 32) - 1
ROOT = "schema_version protocol_version session_id round_id scenario peer_id host_id game map_index content_hash complete errors last_error roster active_seats phases results finishes disconnects injection metrics"
METRICS = "snapshot_hz sent_snapshots received_snapshots ghosts_seen clock_samples window_ms max_clock_error_ms event_latency_p99_ms max_remote_jump_m rtt_ms jitter_ms offset_ms"


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def _fields(value: Any, fields: str, label: str) -> dict[str, Any]:
    _require(type(value) is dict and set(value) == set(fields.split()), f"{label}字段缺失或多余")
    return value


def _integer(value: Any, low: int = 0, high: int = U32) -> int:
    _require(type(value) is int and low <= value <= high, "整数类型或范围错误")
    return value


def _number(value: Any, low: float = 0, high: float = 1e12) -> float:
    _require(type(value) in (int, float) and low <= value <= high, "数值类型或范围错误")
    _require(math.isfinite(value), "数值必须有限")
    return float(value)


def _text(value: Any, limit: int = 64, empty: bool = False) -> str:
    _require(type(value) is str, "文本类型错误")
    try:
        length = len(value.encode("utf-8"))
    except UnicodeError as exc:
        raise ValueError("文本不是有效 UTF-8") from exc
    _require((empty or length > 0) and length <= limit, "文本为空或超长")
    _require(not any(ord(ch) < 32 for ch in value), "文本含控制字符")
    return value


def _array(value: Any, low: int = 0, high: int = 16) -> list[Any]:
    _require(type(value) is list and low <= len(value) <= high, "数组类型或长度错误")
    return value


def _distribution(value: Any, signed: bool = False) -> None:
    row = _fields(value, "p50 p95 p99", "分布")
    values = [_number(row[key], -1e12 if signed else 0) for key in ("p50", "p95", "p99")]
    _require(values == sorted(values), "分布分位数顺序错误")


def _validate_report(value: Any) -> dict[str, Any]:
    report = _fields(value, ROOT, "报告")
    _require(report["schema_version"] == SCHEMA, "报告草案版本错误")
    _require(_integer(report["protocol_version"], 1, 1) == 1, "协议版本错误")
    for key, length in (("session_id", 32), ("content_hash", 64)):
        _require(re.fullmatch(f"[0-9a-f]{{{length}}}", _text(report[key])) is not None, "会话或内容摘要错误")
    for key in ("round_id", "peer_id", "host_id"):
        _integer(report[key], 1)
    _require(report["scenario"] in ("normal", "client_left", "host_left"), "未知场景")
    _require(report["game"] in ("skate", "ski"), "未知项目")
    # 与当前 skate 单赛道、RSSkiMaps.MAPS 四张地图对应；目录改变须修订草案。
    _integer(report["map_index"], 0, 0 if report["game"] == "skate" else 3)
    _require(report["complete"] is True and type(report["errors"]) is list and report["errors"] == [], "报告未完成或包含错误")
    _text(report["last_error"], 256, empty=True)

    seats: set[int] = set()
    owners: set[tuple[int, int]] = set()
    peers: set[int] = set()
    for raw in _array(report["roster"], 2, 4):
        row = _fields(raw, "seat peer_id local_slot name bot", "名单")
        seat = _integer(row["seat"], 1, 4)
        peer = _integer(row["peer_id"], 1)
        owner = (peer, _integer(row["local_slot"], 1, 4))
        _require(seat not in seats and owner not in owners, "全局座位或本地映射重复")
        _text(row["name"], 48)
        _require(type(row["bot"]) is bool, "机器人标记类型错误")
        seats.add(seat)
        owners.add(owner)
        peers.add(peer)
    _require(len(peers) == 2 and report["host_id"] in peers and report["peer_id"] in peers, "主机或报告身份不在两机名单")
    active = [_integer(seat, 1, 4) for seat in _array(report["active_seats"], 0, 4)]
    _require(len(active) == len(set(active)) and set(active) <= seats, "活动座位重复或不存在")

    host = report["peer_id"] == report["host_id"]
    normal = report["scenario"] == "normal" or (report["scenario"] == "client_left" and host)
    expected = ["LOBBY", "COUNTDOWN", "PLAY", "RESULTS", "LOBBY"] if normal else ["LOBBY", "COUNTDOWN", "PLAY", "CLOSED" if host else "MENU"]
    phases = _array(report["phases"], len(expected), len(expected))
    times = []
    for raw, phase in zip(phases, expected, strict=True):
        row = _fields(raw, "phase at_ms", "阶段")
        _require(row["phase"] == phase, "阶段序列错误")
        times.append(_number(row["at_ms"]))
    _require(all(a < b for a, b in zip(times, times[1:], strict=False)), "阶段时间未严格递增")
    _require(not normal or report["last_error"] == "", "完成比赛的报告含离开错误")
    _require(normal or bool(report["last_error"]), "离开端缺少原因")

    finishes: dict[int, dict[str, Any]] = {}
    events: set[str] = set()
    places: set[int] = set()
    for raw in _array(report["finishes"], 0, 4):
        row = _fields(raw, "seat event_id place bonus_count", "完赛")
        seat = _integer(row["seat"], 1, 4)
        place = _integer(row["place"], 1, 4)
        event = _text(row["event_id"])
        _require(re.fullmatch(r"[a-zA-Z0-9_.-]+", event) is not None, "事件 ID 非法")
        _require(seat in seats and seat not in finishes and event not in events and place not in places, "完赛、名次或事件重复")
        _integer(row["bonus_count"], 1, 1)
        finishes[seat] = row
        events.add(event)
        places.add(place)
    _require(places == set(range(1, len(places) + 1)), "完赛名次不连续")

    results = _array(report["results"], 0, 4)
    result_seats = []
    previous_score = None
    rank = 0
    for index, raw in enumerate(results, 1):
        row = _fields(raw, "seat score rank place", "结果")
        seat = _integer(row["seat"], 1, 4)
        score = _integer(row["score"], 0, (1 << 63) - 1)
        if score != previous_score:
            rank = index
        _require(_integer(row["rank"], 1, 4) == rank, "积分竞赛排名错误")
        expected_place = finishes[seat]["place"] if seat in finishes else 0
        _require(_integer(row["place"], 0, 4) == expected_place, "结果与完赛名次不符")
        previous_score = score
        result_seats.append(seat)
    _require(len(set(result_seats)) == len(result_seats) and set(result_seats) == set(active), "结果未唯一覆盖活动名单")
    _require(results == sorted(results, key=lambda row: (-row["score"], row["seat"])), "结果未按分数与座位稳定排序")
    _require(normal or not results, "离开端不应持有最终结果")

    disconnects = _array(report["disconnects"], 0, 1)
    _require(len(disconnects) == (0 if report["scenario"] == "normal" else 1), "断线记录数量错误")
    for raw in disconnects:
        row = _fields(raw, "peer_id at_ms reason", "断线")
        peer = _integer(row["peer_id"], 1)
        _require(peer in peers, "断线身份不存在")
        _require(times[2] <= _number(row["at_ms"]) <= times[3], "断线时间不在比赛与结果或关闭之间")
        _text(row["reason"], 256)
        expected_peer = report["host_id"] if report["scenario"] == "host_left" else next(iter(peers - {report["host_id"]}))
        _require(peer == expected_peer, "断线身份与场景不符")
    expected_active = set()
    if report["scenario"] == "normal":
        expected_active = seats
    elif normal:
        expected_active = {row["seat"] for row in report["roster"] if row["peer_id"] == report["host_id"]}
    _require(set(active) == expected_active, "断线玩家仍在活动名单或正常玩家缺失")

    injection = _fields(report["injection"], "latency_ms jitter_ms loss seed layer", "注入配置")
    _number(injection["latency_ms"], 0, 500)
    _number(injection["jitter_ms"], 0, 500)
    _number(injection["loss"], 0, 1)
    _require(injection["loss"] < 1, "丢包率不能为一")
    _integer(injection["seed"])
    _require(injection["layer"] in ("application", "transport"), "未知丢包注入层")
    metrics = _fields(report["metrics"], METRICS, "指标")
    hz = _integer(metrics["snapshot_hz"], 20, 120)
    _require(hz in (20, 60, 120), "快照频率不支持")
    for key in ("sent_snapshots", "received_snapshots", "ghosts_seen", "clock_samples"):
        _integer(metrics[key], 1)
    _require(metrics["clock_samples"] >= 8, "时钟样本不足")
    window = _number(metrics["window_ms"], 1000)
    _require(abs(metrics["sent_snapshots"] * 1000 / window / hz - 1) <= 0.1 + 1e-9, "实际发送率偏差超过百分之十")
    _require(metrics["ghosts_seen"] == sum(row["peer_id"] != report["peer_id"] for row in report["roster"]), "幽灵数量与远端名单不符")
    for key in ("max_clock_error_ms", "event_latency_p99_ms", "max_remote_jump_m"):
        _number(metrics[key])
    for key in ("rtt_ms", "jitter_ms", "offset_ms"):
        _distribution(metrics[key], key == "offset_ms")
    if not any(injection[key] for key in ("latency_ms", "jitter_ms", "loss")):
        _require(metrics["max_clock_error_ms"] <= 2, "无注入时钟误差超过两毫秒")
    return report


def validate_reports(reports: list[object]) -> None:
    """拒绝不完整、身份不符或互相矛盾的两机候选报告。成功不代表实测通过。"""
    _array(reports, 2, 2)
    first, second = [_validate_report(report) for report in reports]
    shared = "schema_version protocol_version session_id round_id scenario host_id game map_index content_hash injection".split()
    _require(all(first[key] == second[key] for key in shared), "两报告会话、项目、版本或注入配置不同")
    _require(first["peer_id"] != second["peer_id"], "两报告来自同一机器")
    host, client = (first, second) if first["peer_id"] == first["host_id"] else (second, first)
    _require(host["peer_id"] == host["host_id"] and client["peer_id"] != host["host_id"], "必须恰有一份主机报告")
    _require(sorted(first["roster"], key=lambda row: row["seat"]) ==
             sorted(second["roster"], key=lambda row: row["seat"]), "两报告名单或本地映射不一致")
    common = 5 if first["scenario"] == "normal" else 3
    # 建房与加入时间可以不同；只比较主机同步启动后的阶段。
    for left, right in zip(first["phases"][1:common], second["phases"][1:common], strict=True):
        _require(abs(left["at_ms"] - right["at_ms"]) <= 100, "共享阶段时间差超过一百毫秒")
    host_finishes = {row["seat"]: row for row in host["finishes"]}
    _require(all(host_finishes.get(row["seat"]) == row for row in client["finishes"]), "客户完赛记录未经主机确认")
    if first["scenario"] == "normal":
        _require(len(host["finishes"]) == len(client["finishes"]) and host["results"] == client["results"], "两报告完赛或最终成绩不一致")
    else:
        budget = 5000 + first["injection"]["latency_ms"] + first["injection"]["jitter_ms"]
        _require(abs(host["disconnects"][0]["at_ms"] - client["disconnects"][0]["at_ms"]) <= budget, "断线观察差超过检测预算")
    _require(first["metrics"]["snapshot_hz"] == second["metrics"]["snapshot_hz"], "两报告快照配置不一致")


def _pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        _require(key not in result, "JSON 存在重复字段")
        result[key] = value
    return result


def _constant(_: str) -> None:
    raise ValueError("JSON 存在非有限数值")


def load_report(path: Path) -> object:
    """按限长、UTF-8、无重复字段与有限 JSON 规则读取一份报告。"""
    with path.open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    _require(0 < len(data) <= MAX_BYTES, "报告为空或超过一兆字节")
    return json.loads(data.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=_constant)


def main(argv: list[str] | None = None) -> int:
    """命令行退出码仅表示报告校验结果，不输出设备或本机路径。"""
    # Windows 管道可能使用 ASCII/cp1252；不可因中文诊断再次崩溃。
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
    parser = argparse.ArgumentParser(description="检查两份 LAN 草案报告；不代表游戏联机验收")
    parser.add_argument("reports", nargs=2, type=Path, metavar="报告")
    args = parser.parse_args(argv)
    try:
        validate_reports([load_report(path) for path in args.reports])
    except (OSError, ValueError, UnicodeError, RecursionError) as exc:
        # 文件名与解析上下文可能含设备信息，错误输出只给类别。
        message = str(exc) if type(exc) is ValueError else "文件无法读取或 JSON 编码/结构错误"
        print(f"报告校验失败：{message}", file=sys.stderr)
        return 1
    print("两份报告符合草案约定；这不是实际 LAN 通过证据。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
