import math
import random

import pytest

from regina_hub.frames import PHONE_AXIS_MAP, REGINA_DEFAULT_AXIS_MAP, handedness, make_remap
from regina_hub.fusion import GRAVITY, ImuPipeline, Mahony, TimeMapper
from regina_hub.quat import (
    IDENTITY,
    q_angle_between,
    q_conj,
    q_from_axis_angle,
    q_from_rotvec,
    q_mul,
    q_normalize,
    q_rotate,
    q_yaw,
)

RATE = 200.0
DT = 1.0 / RATE


class Truth:
    """Ground-truth motion generator producing ideal (or noisy) IMU readings."""

    def __init__(self, q=IDENTITY, bias=(0.0, 0.0, 0.0), noise=0.0, seed=1):
        self.q = q
        self.t = 0.0
        self.bias = bias
        self.noise = noise
        self.rng = random.Random(seed)

    def step(self, omega_body=(0.0, 0.0, 0.0), lin_world=(0.0, 0.0, 0.0)):
        self.q = q_normalize(q_mul(self.q, q_from_rotvec(tuple(w * DT for w in omega_body))))
        self.t += DT
        f_world = (lin_world[0], lin_world[1] + GRAVITY, lin_world[2])
        accel = q_rotate(q_conj(self.q), f_world)
        n = lambda: self.rng.gauss(0.0, self.noise)  # noqa: E731
        gyro = tuple(w + b + n() for w, b in zip(omega_body, self.bias, strict=False))
        accel = tuple(a + 5 * n() for a in accel)
        return self.t, gyro, accel


def run(pipe, truth, seconds, omega=(0.0, 0.0, 0.0), lin=(0.0, 0.0, 0.0)):
    out = None
    for _ in range(int(round(seconds * RATE))):
        t, g, a = truth.step(omega, lin)
        out = pipe.push(t, g, a) or out
    return out


def deg(x):
    return math.degrees(x)


def test_initial_tilt_from_accel():
    tilt = q_from_axis_angle((1.0, 0.0, 0.0), math.radians(35))
    pipe = ImuPipeline(RATE)
    truth = Truth(q=tilt)
    run(pipe, truth, 0.5)
    up_est = q_rotate(pipe.orientation, (0.0, 0.0, -1.0))
    up_true = q_rotate(tilt, (0.0, 0.0, -1.0))
    assert math.degrees(math.acos(max(-1, min(1, sum(a * b for a, b in zip(up_est, up_true, strict=False)))))) < 1.0


def test_accel_correction_pulls_wrong_tilt_back():
    ahrs = Mahony()
    ahrs.reset_from_accel((0.0, GRAVITY, 0.0))
    ahrs._elapsed = 10.0  # skip startup gain
    ahrs.q = q_from_axis_angle((0.0, 0.0, 1.0), math.radians(20))  # 20 deg roll error
    for _ in range(int(4 * RATE)):
        ahrs.update((0.0, 0.0, 0.0), (0.0, GRAVITY, 0.0), DT, still=True)
    assert deg(q_angle_between(ahrs.q, IDENTITY)) < 1.0


def test_gyro_integration_yaw_90():
    pipe = ImuPipeline(RATE)
    truth = Truth()
    run(pipe, truth, 1.2)          # settle + auto calibration/recenter
    pipe.recenter()
    run(pipe, truth, 1.0, omega=(0.0, math.radians(90), 0.0))
    assert abs(deg(q_yaw(pipe.orientation)) - 90.0) < 1.0


def test_tracks_combined_rotation_against_truth():
    pipe = ImuPipeline(RATE)
    truth = Truth(noise=0.002)
    run(pipe, truth, 1.5)
    pipe.recenter()
    ref = truth.q
    for i in range(400):
        w = (3.0 * math.sin(i * 0.05), 2.0 * math.cos(i * 0.03), 4.0 * math.sin(i * 0.07))
        t, g, a = truth.step(w)
        pipe.push(t, g, a)
    # Compare in the recentered frame: truth relative to the recenter-time yaw.
    from regina_hub.quat import q_twist_y

    truth_rel = q_mul(q_conj(q_twist_y(ref)), truth.q)
    assert deg(q_angle_between(pipe.orientation, truth_rel)) < 3.0


def test_bias_is_estimated_and_removed():
    bias = (0.02, -0.015, 0.01)  # ~1 deg/s
    pipe = ImuPipeline(RATE)
    truth = Truth(bias=bias, noise=0.003)
    run(pipe, truth, 2.0)
    assert pipe.bias.calibrated
    assert "calibrated" in pipe.events and "recentered" in pipe.events
    for est, b in zip(pipe.bias.bias, bias, strict=False):
        assert abs(est - b) < 0.003
    yaw0 = q_yaw(pipe.orientation)
    run(pipe, truth, 20.0)
    assert abs(deg(q_yaw(pipe.orientation) - yaw0)) < 0.5   # no yaw drift while resting


def test_no_calibration_while_moving():
    pipe = ImuPipeline(RATE)
    truth = Truth()
    run(pipe, truth, 3.0, omega=(0.0, 1.5, 0.0))
    assert not pipe.bias.calibrated


def test_forced_calibration_fails_when_moving():
    pipe = ImuPipeline(RATE)
    truth = Truth()
    run(pipe, truth, 1.5)
    pipe.events.clear()
    pipe.request_calibration()
    run(pipe, truth, 6.0, omega=(0.0, 2.0, 0.0))
    assert "calibrate_failed" in pipe.events


def test_recenter_resets_yaw_only():
    pipe = ImuPipeline(RATE)
    truth = Truth()
    run(pipe, truth, 1.5)
    run(pipe, truth, 1.0, omega=(0.0, math.radians(60), 0.0))       # yaw 60
    run(pipe, truth, 0.5, omega=(math.radians(40), 0.0, 0.0))       # pitch up 20
    pipe.recenter()
    assert abs(deg(q_yaw(pipe.orientation))) < 0.5
    fwd = q_rotate(pipe.orientation, (0.0, 0.0, -1.0))
    assert abs(deg(math.asin(fwd[1])) - 20.0) < 1.5


def test_linear_accel_near_zero_at_rest_and_detects_push():
    pipe = ImuPipeline(RATE)
    truth = Truth()
    s = run(pipe, truth, 1.5)
    assert max(abs(v) for v in s.lin_world) < 0.05
    s = run(pipe, truth, 0.05, lin=(0.0, 0.0, -20.0))
    assert s.lin_world[2] < -18.0


def test_timemapper_unwraps_32bit():
    tm = TimeMapper(wrap_bits=32)
    a = tm.device_seconds(0xFFFFFF00)
    b = tm.device_seconds(0x00000100)
    assert math.isclose(b - a, 0x200 / 1e6, rel_tol=1e-9)


def test_timemapper_tracks_min_latency():
    tm = TimeMapper(wrap_bits=None)
    for i, lat in enumerate([0.030, 0.012, 0.050, 0.020]):
        dev = i * 0.02
        tm.observe(dev, 100.0 + dev + lat)
    assert abs(tm.to_hub(1.0) - (101.0 + 0.012)) < 1e-3


@pytest.mark.parametrize("axis_map", [PHONE_AXIS_MAP, REGINA_DEFAULT_AXIS_MAP, ("x", "y", "z"), ("-x", "-y", "z")])
def test_axis_maps_are_proper_rotations(axis_map):
    assert handedness(axis_map) == 1.0


def test_phone_flat_screen_up_reads_gravity_up():
    remap = make_remap(PHONE_AXIS_MAP)
    assert remap((0.0, 0.0, 9.8)) == (0.0, 9.8, -0.0)
    assert remap((0.0, 1.0, 0.0)) == (0.0, 0.0, -1.0)   # phone top -> canonical forward (-Z)
    assert handedness(("x", "y", "-z")) == -1.0


def test_controller_keeps_all_samples_when_latency_estimate_drops():
    from regina_hub.controller import Controller, NullTransport

    c = Controller(1, "sim", "k", "n", NullTransport(), RATE, wrap_bits=None)
    got = 0
    dev_us = 0.0
    for pkt in range(50):
        items = []
        for _ in range(4):
            dev_us += 5000.0
            items.append((dev_us, (0.0, 0.0, 0.0), (0.0, GRAVITY, 0.0)))
        # Packets arrive in a burst: hub time barely moves, so the offset estimate keeps falling.
        got += len(c.ingest_imu(items, hub_now=100.0 + pkt * 0.001))
    assert got == 50 * 4 - 1
