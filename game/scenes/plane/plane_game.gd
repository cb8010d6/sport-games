extends RSPartyGame
## 螺旋桨飞机 (propeller plane, a P1 tilt game): tilt the controller to bank and to climb or
## dive, and fly through as many rings as possible before time runs out. Any grip works: the
## pose held when pressing A in the lobby is "level flight" (RSTiltStick), and holding D for a
## second (hub recenter) re-levels mid-flight.
##
## Debug: `-- --demo=N` (autopiloted planes), `-- --round=S` shortens the round.

const RING_COUNT := 24
const RING_RADIUS := 7.0        ## pass within this of the centre to score
const MISS_RADIUS := 21.0       ## crossing a ring's plane this close (but outside) is a miss
const BOUNDS := 470.0           ## beyond this the plane turns back on its own
const CEILING := 170.0
const START_BACK := 70.0        ## start distance before the first ring


class Ring:
	var pos: Vector3
	var normal: Vector3          ## direction of travel through the ring
	var gold := false


class Pilot:
	var stick := RSTiltStick.new()
	var stick_val := Vector2.ZERO
	var fake_boost := false
	var plane: RSPlane
	var highlight: MeshInstance3D
	var next_ring := 0
	var rings := 0
	var combo := 0
	var best_combo := 0
	var perfects := 0
	var recover := 0.0           ## seconds left of the post-crash respawn
	var out_of_bounds := false


var _round_time := 90.0
var _time_left := 90.0
var _rings: Array[Ring] = []
var _island: RSIsland
var _lobby_angle := 0.6
var _ring_clock := 0.0


func _game_name() -> String:
	return tr("螺旋桨飞机")


func _oled_name() -> String:
	return "PLANE"


func _how_to_play() -> String:
	return (tr("左右倾斜手柄 = 转弯　向前压 = 俯冲　向后拉 = 爬升　按住 B = 加速\n") +
		tr("穿过圆环得分，连续穿环有连击加分，金环 300 分。限时 %d 秒。\n") % int(_round_time) +
		tr("怎么拿都行：按 A 准备时的姿势就是“平飞”。飞行中长按 D 1 秒可以重新设定。"))


func _parse_arg(arg: String) -> void:
	if arg.begins_with("--round="):
		_round_time = maxf(5.0, float(arg.get_slice("=", 1)))


func _pilot(p: Player) -> Pilot:
	return p.data


# --------------------------------------------------------------------------- world ----

func _setup_world() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.2, 0.44, 0.88)
	sky_mat.sky_horizon_color = Color(0.76, 0.86, 0.98)
	sky_mat.ground_horizon_color = Color(0.76, 0.86, 0.98)
	sky_mat.ground_bottom_color = Color(0.2, 0.4, 0.6)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
	env.ssao_radius = 1.5
	env.ssao_intensity = 1.2
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.04
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.fog_enabled = true
	env.fog_light_color = Color(0.74, 0.84, 0.97)
	env.fog_density = 0.0005
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -35, 0)
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 260.0
	add_child(sun)

	_island = RSIsland.new()
	add_child(_island)
	_build_rings()


func _build_rings() -> void:
	var white := RSMeshUtil.toon_material(Color(0.98, 0.98, 1.0), 0.6)
	var gold := RSMeshUtil.toon_material(Color(1.0, 0.76, 0.12), 0.8, 0.3)
	gold.set_shader_parameter("emission_color", Color(0.4, 0.25, 0.0))
	var torus := TorusMesh.new()
	torus.inner_radius = RING_RADIUS - 0.4
	torus.outer_radius = RING_RADIUS + 0.6
	torus.rings = 48
	torus.ring_segments = 12
	# A wobbly loop around the island, rising and falling, always well above the ground.
	var pts: Array[Vector3] = []
	for i in RING_COUNT:
		var a := TAU * i / RING_COUNT
		var r := 190.0 + 45.0 * sin(3.0 * a)
		var p := Vector3(r * cos(a), 0.0, r * sin(a))
		p.y = maxf(42.0 + 22.0 * sin(2.0 * a + 1.0), _island.ground_height(p.x, p.z) + 20.0)
		pts.append(p)
	for i in RING_COUNT:
		var ring := Ring.new()
		ring.pos = pts[i]
		ring.normal = (pts[(i + 1) % RING_COUNT] - pts[(i + RING_COUNT - 1) % RING_COUNT]).normalized()
		ring.gold = i % 6 == 5
		_rings.append(ring)
		var mi := MeshInstance3D.new()
		mi.mesh = torus
		mi.material_override = gold if ring.gold else white
		mi.transform = Transform3D(Basis(Quaternion(Vector3.UP, ring.normal)), ring.pos)
		add_child(mi)


func _lobby_process(delta: float) -> void:
	_lobby_angle += delta * 0.06
	lobby_cam.position = Vector3(cos(_lobby_angle) * 340.0, 150.0, sin(_lobby_angle) * 340.0)
	lobby_cam.look_at(Vector3(0, 15, 0))


# ------------------------------------------------------------------------- pilots ----

func _player_added(p: Player) -> void:
	var s := Pilot.new()
	p.data = s
	s.plane = RSPlane.new(color_of(p))
	s.plane.visible = false
	add_child(s.plane)
	# The next ring glows in the player's colour, only in that player's view.
	var hl := TorusMesh.new()
	hl.inner_radius = RING_RADIUS - 0.9
	hl.outer_radius = RING_RADIUS + 1.3
	hl.rings = 48
	hl.ring_segments = 12
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color_of(p)
	s.highlight = MeshInstance3D.new()
	s.highlight.mesh = hl
	s.highlight.material_override = mat
	s.highlight.layers = 1 << p.c.player
	s.highlight.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	s.highlight.visible = false
	add_child(s.highlight)


func _player_removed(p: Player) -> void:
	_pilot(p).plane.queue_free()
	_pilot(p).highlight.queue_free()


func _player_ready(p: Player, is_ready: bool) -> void:
	if is_ready:
		_pilot(p).stick.capture(p.c.motion_orientation())


func _player_recentered(p: Player) -> void:
	_pilot(p).stick.capture(p.c.motion_orientation())
	p.popup(tr("已重设平飞姿势"))


func _round_started(list: Array) -> void:
	_time_left = _round_time
	var r0 := _rings[0]
	var flat := Vector3(r0.normal.x, 0.0, r0.normal.z).normalized()
	var right := flat.cross(Vector3.UP)
	var yaw := atan2(-flat.x, -flat.z)
	for i in list.size():
		var p: Player = list[i]
		var s := _pilot(p)
		var lateral: float = [-6.0, 6.0, -18.0, 18.0][i]
		s.plane.place(r0.pos - flat * (START_BACK + (i >> 1) * 14.0) + right * lateral, yaw)
		s.plane.visible = true
		s.highlight.visible = true
		s.next_ring = 0
		s.rings = 0
		s.combo = 0
		s.best_combo = 0
		s.perfects = 0
		s.recover = 0.0
		send_ui(p, {"clear": true, "title": "PLANE %ds" % int(_round_time), "main": "0", "bar": {"pct": 100, "label": "BOOST"},
			"legends": ["", "BOOST", "", null]})
		_follow_cam(p, 0.0, true)


func _countdown_process(delta: float) -> void:
	for p: Player in players.values():
		_pilot(p).stick_val = _read_stick(p)
		_follow_cam(p, delta, false)
	_update_highlights(delta)


func _play_process(delta: float) -> void:
	_time_left -= delta
	for p: Player in players.values():
		_fly(p, delta)
		_follow_cam(p, delta, false)
		_update_oled(p)
	_update_highlights(delta)
	if _time_left <= 0.0:
		_time_left = 0.0
		finish_round()


func _results_process(delta: float) -> void:
	_update_highlights(delta)


func _to_lobby() -> void:
	super._to_lobby()
	for p: Player in players.values():
		_pilot(p).plane.visible = false
		_pilot(p).highlight.visible = false


func _result_detail(p: Player) -> String:
	var s := _pilot(p)
	return tr("穿环 %d   最高连击 %d   完美 %d") % [s.rings, s.best_combo, s.perfects]


func _update_highlights(delta: float) -> void:
	_ring_clock += delta
	for p: Player in players.values():
		var s := _pilot(p)
		if s.highlight.visible:
			var ring := _rings[s.next_ring]
			var pulse := 1.0 + 0.06 * sin(_ring_clock * 6.0)
			s.highlight.transform = Transform3D(Basis(Quaternion(Vector3.UP, ring.normal)).scaled(Vector3.ONE * pulse), ring.pos)


# -------------------------------------------------------------------------- flight ----

func _read_stick(p: Player) -> Vector2:
	if p.fake:
		return _autopilot(p)
	if not p.c.connected:
		return Vector2.ZERO
	return _pilot(p).stick.stick(p.c.motion_orientation())


func _fly(p: Player, dt: float) -> void:
	var s := _pilot(p)
	var pl := s.plane
	var stick := _read_stick(p)
	var boost := s.fake_boost if p.fake else p.c.is_pressed(RSController.BTN_B)
	s.out_of_bounds = Vector2(pl.position.x, pl.position.z).length() > BOUNDS
	if s.out_of_bounds:
		var local := pl.global_transform.affine_inverse() * Vector3(0, pl.position.y, 0)
		stick.x = clampf(atan2(local.x, -local.z) * 1.5, -1.0, 1.0)
	if pl.position.y > CEILING:
		stick.y = minf(stick.y, -0.4)
	if s.recover > 0.0:
		s.recover -= dt
		stick = Vector2(0.0, 0.3)
		boost = false
		pl.visible = s.recover <= 0.0 or int(s.recover * 10.0) % 2 == 0
	s.stick_val = stick
	var prev := pl.position
	pl.fly(stick, boost, dt)
	_check_rings(p, prev, pl.position)
	var ground := _island.ground_height(pl.position.x, pl.position.z)
	if pl.position.y < maxf(ground, 0.0) + 1.6 and s.recover <= 0.0:
		_crash(p, ground < 0.0)


func _crash(p: Player, water: bool) -> void:
	var s := _pilot(p)
	var pl := s.plane
	s.combo = 0
	s.recover = 1.6
	pl.position.y = maxf(_island.ground_height(pl.position.x, pl.position.z), 0.0) + 24.0
	pl.pitch = 0.2
	pl.clear_trail()
	p.popup(tr("落水！") if water else tr("撞山了！"), Color(1.0, 0.55, 0.45))
	toast(p, "SPLASH!" if water else "CRASH!", 900)
	haptic(p, "crash")


func _check_rings(p: Player, a: Vector3, b: Vector3) -> void:
	# Look at the next ring and the one after, so cutting a corner past a missed ring still
	# counts the following one.
	var s := _pilot(p)
	for step in 2:
		var ring := _rings[(s.next_ring + step) % RING_COUNT]
		var sa := (a - ring.pos).dot(ring.normal)
		var sb := (b - ring.pos).dot(ring.normal)
		if sa >= 0.0 or sb < 0.0:
			continue
		var off := a.lerp(b, sa / (sa - sb)).distance_to(ring.pos)
		if off <= RING_RADIUS:
			if step == 1:
				_ring_result(p, false, 0.0)
			_ring_result(p, true, off)
			return
		if step == 0 and off <= MISS_RADIUS:
			_ring_result(p, false, off)
			return


func _ring_result(p: Player, hit: bool, off: float) -> void:
	var s := _pilot(p)
	var ring := _rings[s.next_ring]
	s.next_ring = (s.next_ring + 1) % RING_COUNT
	if not hit:
		s.combo = 0
		p.popup(tr("错过"), Color(1.0, 0.65, 0.55))
		toast(p, "MISS", 500)
		return
	s.rings += 1
	s.combo += 1
	s.best_combo = maxi(s.best_combo, s.combo)
	var pts := (300 if ring.gold else 100) + 20 * mini(s.combo - 1, 10)
	var perfect := off < RING_RADIUS * 0.35
	if perfect:
		pts += 50
		s.perfects += 1
	p.score += pts
	var label := (tr("完美 +%d") if perfect else "+%d") % pts
	if s.combo >= 3:
		label += tr("  连击 ×%d") % s.combo
	p.popup(label, Color(1.0, 0.85, 0.3) if ring.gold or perfect else Color.WHITE)
	toast(p, "+%d" % pts, 600)
	haptic(p, "good" if ring.gold or perfect else "hit")


func _autopilot(p: Player) -> Vector2:
	## Bot pilot: steer at the next ring, offset a little per player so planes don't overlap.
	var s := _pilot(p)
	var pl := s.plane
	var ring := _rings[s.next_ring]
	var target := ring.pos + ring.normal.cross(Vector3.UP).normalized() * (p.c.player - 2.5) * 1.5
	var local := pl.global_transform.affine_inverse() * target
	var yaw_err := atan2(local.x, -local.z)
	var flat := Vector2(target.x - pl.position.x, target.z - pl.position.z).length()
	var want_pitch := clampf(atan2(target.y - pl.position.y, flat), -0.6, 0.6)
	var stick := Vector2(clampf(yaw_err * 2.0, -1.0, 1.0), clampf(want_pitch * 1.6 / deg_to_rad(RSPlane.MAX_PITCH_DEG), -1.0, 1.0))
	s.fake_boost = absf(yaw_err) < 0.12 and flat > 60.0
	# Mirror the stick into a controller pose so the tilt widget moves like a real one.
	var w := Vector3(tan(stick.x * s.stick.max_roll), 1.0, tan(stick.y * s.stick.max_pitch)).normalized()
	p.c.orientation = Quaternion(Vector3.UP, w)
	return stick


func _follow_cam(p: Player, dt: float, snap: bool) -> void:
	var pl := _pilot(p).plane
	var fwd := pl.forward()
	var want := pl.position - fwd * 11.0 + Vector3.UP * 3.6
	var k := 1.0 if snap else 1.0 - exp(-dt * 5.0)
	p.cam.position = p.cam.position.lerp(want, k)
	p.cam.look_at(pl.position + fwd * 12.0 + Vector3.UP * 1.2, Vector3.UP.lerp(pl.basis.y, 0.3).normalized())
	p.cam.fov = lerpf(p.cam.fov, 84.0 if pl.boosting else 72.0, k * 0.6)


func _update_oled(p: Player) -> void:
	var t := ceili(_time_left)
	var fuel := int(round(_pilot(p).plane.boost_fuel * 10.0)) * 10
	var key := "%d|%d|%d" % [t, p.score, fuel]
	if key == p.oled_key:
		return
	p.oled_key = key
	send_ui(p, {"title": "PLANE %ds" % t, "main": str(p.score), "bar": {"pct": fuel, "label": "BOOST"}})


# ---------------------------------------------------------------------------- HUD ----

func _draw_hud(h: PlayerHud, p: Player, k: float) -> void:
	var s := _pilot(p)
	var pl := s.plane
	var sz := h.size
	var col := color_of(p)
	var sub := tr("穿环 %d") % s.rings + (tr("　连击 ×%d") % s.combo if s.combo >= 2 else "")
	draw_text(h, sub, Vector2(20, 88) * k, 20 * k, Color(0.92, 0.95, 1.0))
	# Boost bar.
	var bar := Rect2(Vector2(20, 100) * k, Vector2(170, 10) * k)
	h.draw_rect(bar, Color(0, 0, 0, 0.35))
	h.draw_rect(Rect2(bar.position, Vector2(bar.size.x * pl.boost_fuel, bar.size.y)), Color(1.0, 0.78, 0.25) if pl.boosting else Color(0.95, 0.95, 1.0, 0.85))
	draw_text(h, tr("B 加速"), Vector2(198, 111) * k, 14 * k, Color(0.9, 0.92, 1.0, 0.8))
	draw_text(h, tr("%d km/h　高度 %d m") % [roundi(pl.speed * 3.6), roundi(pl.position.y)], Vector2(20, sz.y / k - 20) * k, 17 * k, Color(0.92, 0.95, 1.0))

	# Tilt widget: where the stick is, so players learn how far to tilt.
	var tc := Vector2(sz.x - 72 * k, sz.y - 72 * k)
	var stick_r := 46 * k
	h.draw_circle(tc, stick_r, Color(0, 0, 0, 0.3))
	h.draw_arc(tc, stick_r, 0, TAU, 48, Color(1, 1, 1, 0.6), 2.0 * k, true)
	h.draw_line(tc - Vector2(stick_r, 0), tc + Vector2(stick_r, 0), Color(1, 1, 1, 0.25), 1.0)
	h.draw_line(tc - Vector2(0, stick_r), tc + Vector2(0, stick_r), Color(1, 1, 1, 0.25), 1.0)
	h.draw_circle(tc + Vector2(s.stick_val.x, -s.stick_val.y) * stick_r, 9 * k, col.lightened(0.2))
	draw_text(h, tr("倾斜"), tc + Vector2(0, -stick_r - 8 * k), 14 * k, Color(1, 1, 1, 0.8), true)

	# Marker on the next ring, or an edge arrow when it's off screen.
	if phase in [Phase.COUNTDOWN, Phase.PLAY]:
		var ring := _rings[s.next_ring]
		var sp := p.cam.unproject_position(ring.pos)
		var behind := p.cam.is_position_behind(ring.pos)
		var margin := 50.0 * k
		var area := Rect2(Vector2(margin, margin), sz - Vector2(margin, margin) * 2.0)
		var dist := roundi(pl.position.distance_to(ring.pos))
		if not behind and area.has_point(sp):
			var d := 10.0 * k
			h.draw_polyline(PackedVector2Array([sp + Vector2(0, -d), sp + Vector2(d, 0), sp + Vector2(0, d), sp + Vector2(-d, 0), sp + Vector2(0, -d)]), col.lightened(0.3), 3.0 * k, true)
			draw_text(h, "%d m" % dist, sp + Vector2(0, 30 * k), 16 * k, Color.WHITE, true)
		else:
			var center := sz * 0.5
			var dir := sp - center
			if behind:
				dir = -dir
			if dir.length() < 1.0:
				dir = Vector2(0, 1)
			var t := minf(area.size.x * 0.5 / maxf(absf(dir.x), 0.001), area.size.y * 0.5 / maxf(absf(dir.y), 0.001))
			var at := center + dir * t
			var f := dir.normalized()
			var side := Vector2(-f.y, f.x)
			h.draw_colored_polygon(PackedVector2Array([at + f * 18 * k, at - f * 10 * k + side * 14 * k, at - f * 10 * k - side * 14 * k]), col.lightened(0.3))
			draw_text(h, "%d m" % dist, at - f * 34 * k + Vector2(0, 6 * k), 15 * k, Color.WHITE, true)

	var warn := ""
	if s.out_of_bounds:
		warn = tr("飞出范围，自动掉头")
	elif s.recover > 0.0:
		warn = tr("重新起飞……")
	if not warn.is_empty():
		draw_text(h, warn, Vector2(sz.x * 0.5, sz.y * 0.62), 26 * k, Color(1.0, 0.75, 0.55), true)


func _draw_overlay(o: Overlay, k: float) -> void:
	if phase == Phase.COUNTDOWN:
		draw_text(o, tr("倾斜手柄试试手感"), Vector2(o.size.x * 0.5, o.size.y * 0.45 + 60 * k), 26 * k, Color(0.92, 0.95, 1.0), true)
	elif phase in [Phase.PLAY, Phase.RESULTS]:
		draw_clock(o, _time_left, k)
