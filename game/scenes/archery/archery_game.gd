extends RSPartyGame
## 射箭 (archery, a P1 tilt game): point the controller to aim, hold A to draw the bow (longer =
## stronger), let go to shoot. 3 rounds of 3 arrows at 15 / 25 / 40 m, with wind from round 2.
## Aim is relative: every round starts by capturing the current pose as "straight ahead",
## which also cancels gyro yaw drift (hold D for a second to re-capture mid-round).
## Every player shoots at their own lane at the same time, split screen.

const ROUNDS := [
	{"dist": 15.0, "wind": [0.0, 0.0]},
	{"dist": 25.0, "wind": [0.4, 1.5]},
	{"dist": 40.0, "wind": [1.5, 3.2]},
]
const ARROWS := 3
const LANE_SPACING := 7.0
const EYE := Vector3(0, 1.6, 0)
const FACE_Y := 1.35               ## target centre height
const FACE_RADIUS := 1.2           ## 10 scoring rings of 0.12 m
const BOSS_RADIUS := 1.45          ## straw boss around the face: arrows stick, 0 points
const GRAVITY := 5.0               ## a bit softer than real, for an arcade feel
const WIND_ACCEL := 1.2            ## m/s^2 of drift per m/s of wind
const FULL_DRAW := 1.0             ## seconds to full draw
const SPEED_MIN := 18.0
const SPEED_MAX := 62.0
const MIN_POWER := 0.2             ## releasing below this lowers the bow without shooting
const SHOT_WAIT := 20.0            ## effective SHOOT seconds available for each waiting arrow
const INTRO_TIME := 2.2            ## round banner, aim is captured when it ends
const SUMMARY_TIME := 3.0
const MAX_YAW := 0.70             ## rad (40 deg)
const MAX_PITCH := 0.61           ## rad (35 deg)
const BOW_R := 0.9                 ## bow arc radius
const BOW_HALF := 0.3              ## half the arc angle, rad
const BOW_GRIP := 0.75             ## grip distance ahead of the eye
const FACE_COLORS := [Color(0.97, 0.97, 0.95), Color(0.12, 0.12, 0.14), Color(0.2, 0.55, 0.92), Color(0.92, 0.22, 0.2), Color(1.0, 0.82, 0.15)]

enum Stage { INTRO, SHOOT, SUMMARY }


class Arrow:
	var node: Node3D
	var vel: Vector3
	var age := 0.0
	var flying := true


class Archer:
	var lane_x := 0.0
	var aim_ref := Quaternion.IDENTITY
	var aim := Vector3.FORWARD      ## smoothed world aim direction
	var drawing := false
	var draw_t := 0.0
	var wait_t := 0.0
	var arrows_left := ARROWS
	var arrows: Array[Arrow] = []   ## this round's arrows (flying or stuck)
	var hits: Array[Vector3] = []   ## this round: (x, y on the face, ring score)
	var round_scores: Array[int] = []
	var tens := 0
	var target: Node3D
	var flag: Node3D
	var rig: Node3D                 ## first-person bow, child of the camera
	var string_top: MeshInstance3D
	var string_bottom: MeshInstance3D
	var nocked: Node3D
	var bot_wait := 0.0
	var bot_aim := Vector3.FORWARD

	func power() -> float:
		return clampf(draw_t / FULL_DRAW, 0.0, 1.0) if drawing else 0.0


var _round := 0
var _stage := Stage.INTRO
var _stage_time := 0.0
var _wind := 0.0                  ## m/s, + = blowing to the right
var _rng := RandomNumberGenerator.new()
var _lobby_t := 0.0
var _arrow_mesh: Array = []       ## [mesh, material, transform] parts of an arrow


func _game_name() -> String:
	return tr("射箭")


func _oled_name() -> String:
	return "ARCHERY"


func _how_to_play() -> String:
	return (tr("用手柄指向目标瞄准（屏幕中间的准星）　按住 A 拉弓，越久力度越大，松开放箭\n") +
		tr("3 轮各 3 支箭：15 米、25 米、40 米，第 2 轮起有风。远靶箭会往下掉，要瞄高一点。\n") +
		tr("每轮开始时手柄的指向就是“正前方”；中途偏了就长按 D 1 秒重新对准。"))


func _archer(p: Player) -> Archer:
	return p.data


# --------------------------------------------------------------------------- world ----

func _setup_world() -> void:
	_rng.seed = 3
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.24, 0.48, 0.9)
	sky_mat.sky_horizon_color = Color(0.8, 0.88, 0.98)
	sky_mat.ground_horizon_color = Color(0.8, 0.88, 0.98)
	sky_mat.ground_bottom_color = Color(0.35, 0.45, 0.4)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.1
	env.fog_enabled = true
	env.fog_light_color = Color(0.8, 0.88, 0.97)
	env.fog_density = 0.003
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 1.2
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 90.0
	add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(600, 600)
	ground.mesh = plane
	ground.material_override = RSMeshUtil.toon_material(Color(0.5, 0.76, 0.4), 0.0, 0.9)
	add_child(ground)
	# Mown lanes and the shooting line.
	var lane_mat := RSMeshUtil.toon_material(Color(0.44, 0.7, 0.35), 0.0, 0.9)
	for i in 4:
		var strip := MeshInstance3D.new()
		var sm := PlaneMesh.new()
		sm.size = Vector2(4.0, 52.0)
		strip.mesh = sm
		strip.material_override = lane_mat
		strip.position = Vector3(_lane_x(i + 1), 0.01, -24.0)
		add_child(strip)
	var line := MeshInstance3D.new()
	line.mesh = RSMeshUtil.rounded_box(Vector3(LANE_SPACING * 4.0 + 2.0, 0.04, 0.25), 0.02)
	line.material_override = RSMeshUtil.toon_material(Color(0.98, 0.98, 0.96), 0.1)
	line.position = Vector3(0, 0.02, -0.4)
	add_child(line)
	# Distance boards along the side.
	for r in ROUNDS:
		var board := Label3D.new()
		board.text = "%d m" % int(r["dist"])
		board.font = font
		board.font_size = 64
		board.pixel_size = 0.008
		board.outline_size = 14
		board.position = Vector3(_lane_x(1) - 5.0, 0.5, -float(r["dist"]))
		add_child(board)
	# Rolling hills and trees around the range.
	var hill_mat := RSMeshUtil.toon_material(Color(0.42, 0.66, 0.38), 0.15, 0.9)
	var sphere := SphereMesh.new()
	for k in 14:
		var hill := MeshInstance3D.new()
		hill.mesh = sphere
		hill.material_override = hill_mat
		var a := lerpf(-1.3, 1.3, k / 13.0)
		var d := _rng.randf_range(95.0, 140.0)
		var s := _rng.randf_range(35.0, 60.0)
		hill.scale = Vector3(s * 1.6, s * 0.45, s)
		hill.position = Vector3(sin(a) * d, -s * 0.12, -cos(a) * d)
		add_child(hill)
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 1.6
	cone.height = 5.0
	cone.radial_segments = 7
	var tree_mat := RSMeshUtil.toon_material(Color(0.2, 0.5, 0.28), 0.25, 0.8)
	for k in 60:
		var side := -1.0 if k % 2 == 0 else 1.0
		var tree := MeshInstance3D.new()
		tree.mesh = cone
		tree.material_override = tree_mat
		var s := _rng.randf_range(0.8, 1.5)
		tree.scale = Vector3(s, s * _rng.randf_range(0.9, 1.4), s)
		tree.position = Vector3(side * _rng.randf_range(22.0, 45.0), 2.5 * tree.scale.y, -_rng.randf_range(-5.0, 75.0))
		add_child(tree)

	_build_arrow_parts()
	shot_times = [0.5, 2.0, 6.0, 14.0, 22.0, 31.0, 45.0, 60.0]
	lobby_cam.fov = 50
	lobby_cam.far = 800


func _lane_x(player: int) -> float:
	return (player - 2.5) * LANE_SPACING


func _build_target(color: Color) -> Node3D:
	## Straw boss on an A-frame stand, face towards +Z, centred at FACE_Y.
	var t := Node3D.new()
	var wood := RSMeshUtil.toon_material(Color(0.55, 0.38, 0.24), 0.2)
	for sx in [-1.0, 1.0]:
		var leg := MeshInstance3D.new()
		leg.mesh = RSMeshUtil.rounded_box(Vector3(0.14, 2.6, 0.14), 0.05)
		leg.material_override = wood
		leg.position = Vector3(sx * 0.9, 1.2, -0.35)
		leg.rotation = Vector3(deg_to_rad(-12), 0, sx * deg_to_rad(-8))
		t.add_child(leg)
	var boss := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BOSS_RADIUS
	cyl.bottom_radius = BOSS_RADIUS
	cyl.height = 0.45
	cyl.radial_segments = 40
	boss.mesh = cyl
	boss.material_override = RSMeshUtil.toon_material(Color(0.86, 0.76, 0.5), 0.2, 0.9)
	boss.rotation.x = PI / 2.0
	boss.position = Vector3(0, FACE_Y, -0.25)
	t.add_child(boss)
	for i in FACE_COLORS.size():
		var disc := MeshInstance3D.new()
		var dm := CylinderMesh.new()
		dm.top_radius = FACE_RADIUS * (1.0 - i * 0.2)
		dm.bottom_radius = dm.top_radius
		dm.height = 0.01
		dm.radial_segments = 48
		disc.mesh = dm
		disc.material_override = RSMeshUtil.toon_material(FACE_COLORS[i], 0.05, 0.9)
		disc.rotation.x = PI / 2.0
		disc.position = Vector3(0, FACE_Y, 0.005 + i * 0.004)
		t.add_child(disc)
	# Lane number plate in the player's colour.
	var plate := MeshInstance3D.new()
	plate.mesh = RSMeshUtil.rounded_box(Vector3(0.9, 0.35, 0.06), 0.05)
	plate.material_override = RSMeshUtil.toon_material(color, 0.3)
	plate.position = Vector3(0, FACE_Y + BOSS_RADIUS + 0.3, -0.25)
	t.add_child(plate)
	return t


func _build_flag(color: Color) -> Node3D:
	## Wind flag: a pole with a pennant that swings to where the wind blows.
	var pole := Node3D.new()
	var stick := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.04
	cyl.bottom_radius = 0.05
	cyl.height = 4.0
	stick.mesh = cyl
	stick.material_override = RSMeshUtil.toon_material(Color(0.9, 0.9, 0.92), 0.2)
	stick.position.y = 2.0
	pole.add_child(stick)
	var pivot := Node3D.new()
	pivot.name = "Pennant"
	pivot.position.y = 3.7
	pole.add_child(pivot)
	var cloth := MeshInstance3D.new()
	var prism := PrismMesh.new()
	prism.size = Vector3(0.5, 1.1, 0.03)
	cloth.mesh = prism
	cloth.material_override = RSMeshUtil.toon_material(color, 0.3)
	cloth.rotation.z = -PI / 2.0
	cloth.position.x = 0.55
	pivot.add_child(cloth)
	return pole


func _build_arrow_parts() -> void:
	var shaft := CylinderMesh.new()
	shaft.top_radius = 0.012
	shaft.bottom_radius = 0.012
	shaft.height = 0.78
	shaft.radial_segments = 6
	var tip := CylinderMesh.new()
	tip.top_radius = 0.0
	tip.bottom_radius = 0.025
	tip.height = 0.07
	tip.radial_segments = 6
	var along := Basis(Vector3.RIGHT, -PI / 2.0)   # cylinder +Y -> -Z (arrow points along -Z)
	_arrow_mesh = [
		[shaft, RSMeshUtil.toon_material(Color(0.78, 0.62, 0.42), 0.2), Transform3D(along, Vector3(0, 0, 0.39))],
		[tip, RSMeshUtil.toon_material(Color(0.3, 0.32, 0.36), 0.4), Transform3D(along, Vector3(0, 0, -0.03))],
	]


func _make_arrow(color: Color, layers: int = 1) -> Node3D:
	## Arrow with its tip at the origin, pointing -Z.
	var a := Node3D.new()
	for part in _arrow_mesh:
		var mi := MeshInstance3D.new()
		mi.mesh = part[0]
		mi.material_override = part[1]
		mi.transform = part[2]
		mi.layers = layers
		a.add_child(mi)
	var fl_mat := RSMeshUtil.toon_material(color, 0.3)
	for r in [0.0, PI / 2.0]:
		var fl := MeshInstance3D.new()
		fl.mesh = RSMeshUtil.rounded_box(Vector3(0.09, 0.004, 0.14), 0.002)
		fl.material_override = fl_mat
		fl.transform = Transform3D(Basis(Vector3.BACK, r), Vector3(0, 0, 0.7))
		fl.layers = layers
		a.add_child(fl)
	return a


func _lobby_process(delta: float) -> void:
	_lobby_t += delta
	lobby_cam.position = Vector3(sin(_lobby_t * 0.15) * 6.0, 4.5, 9.0)
	lobby_cam.look_at(Vector3(0, 1.2, -25))


# ------------------------------------------------------------------------ archers ----

func _player_added(p: Player) -> void:
	var s := Archer.new()
	p.data = s
	s.lane_x = _lane_x(p.c.player)
	s.target = _build_target(color_of(p))
	s.target.position = Vector3(s.lane_x, 0, -float(ROUNDS[0]["dist"]))
	add_child(s.target)
	s.flag = _build_flag(color_of(p))
	s.flag.position = Vector3(s.lane_x + 2.2, 0, -float(ROUNDS[0]["dist"]) + 0.5)
	add_child(s.flag)
	p.cam.fov = 55
	p.cam.position = Vector3(s.lane_x, EYE.y, EYE.z)
	_build_bow(p)


func _player_removed(p: Player) -> void:
	var s := _archer(p)
	s.target.queue_free()
	s.flag.queue_free()
	_clear_arrows(s)


func _build_bow(p: Player) -> void:
	## First-person bow on the camera, only on this player's layer. The bow is a circular arc
	## in the camera's y-z plane: grip BOW_GRIP ahead, limbs curving back toward the eye.
	var s := _archer(p)
	var layer := 1 << p.c.player
	s.rig = Node3D.new()
	s.rig.position = Vector3(-0.2, -0.07, 0)
	s.rig.rotation.z = deg_to_rad(8)
	p.cam.add_child(s.rig)
	var wood := RSMeshUtil.toon_material(color_of(p).darkened(0.25), 0.3)
	var pts: Array[Vector3] = []
	for i in 13:
		var th := lerpf(-BOW_HALF, BOW_HALF, i / 12.0)
		pts.append(Vector3(0, BOW_R * sin(th), BOW_R - BOW_GRIP - BOW_R * cos(th)))
	for i in 12:
		var seg := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		var thick := 0.022 if absi(i - 6) < 2 else 0.014
		cyl.top_radius = thick
		cyl.bottom_radius = thick
		cyl.height = pts[i].distance_to(pts[i + 1]) + 0.01
		cyl.radial_segments = 6
		seg.mesh = cyl
		seg.material_override = wood
		seg.layers = layer
		seg.transform = Transform3D(Basis(Quaternion(Vector3.UP, (pts[i + 1] - pts[i]).normalized())), (pts[i] + pts[i + 1]) * 0.5)
		s.rig.add_child(seg)
	var string_mat := RSMeshUtil.toon_material(Color(0.95, 0.95, 0.95), 0.2)
	var string_mesh := CylinderMesh.new()
	string_mesh.top_radius = 0.003
	string_mesh.bottom_radius = 0.003
	string_mesh.height = 1.0
	string_mesh.radial_segments = 4
	for k in 2:
		var st := MeshInstance3D.new()
		st.mesh = string_mesh
		st.material_override = string_mat
		st.layers = layer
		s.rig.add_child(st)
		if k == 0:
			s.string_top = st
		else:
			s.string_bottom = st
	s.nocked = _make_arrow(color_of(p), layer)
	s.rig.add_child(s.nocked)
	_pose_bow(s)


func _pose_bow(s: Archer) -> void:
	var tip_z := BOW_R - BOW_GRIP - BOW_R * cos(BOW_HALF)
	var tip_y := BOW_R * sin(BOW_HALF)
	var nock := Vector3(0, 0, tip_z + 0.06 + 0.32 * s.power())
	for k in 2:
		var tip := Vector3(0, tip_y if k == 0 else -tip_y, tip_z)
		var st := s.string_top if k == 0 else s.string_bottom
		var d := tip - nock
		st.transform = Transform3D(Basis(Quaternion(Vector3.UP, d.normalized())) * Basis.from_scale(Vector3(1, d.length(), 1)), (tip + nock) * 0.5)
	s.nocked.visible = s.arrows_left > 0 and _stage == Stage.SHOOT and not _arrow_in_flight(s)
	s.nocked.position = nock - Vector3(0, 0, 0.78)


func _clear_arrows(s: Archer) -> void:
	for a in s.arrows:
		a.node.queue_free()
	s.arrows.clear()
	s.hits.clear()


func _arrow_in_flight(s: Archer) -> bool:
	for a in s.arrows:
		if a.flying:
			return true
	return false


# ------------------------------------------------------------------------- rounds ----

func _round_started(list: Array) -> void:
	for p: Player in list:
		var s := _archer(p)
		s.round_scores.clear()
		s.tens = 0
	_begin_round(0)


func _begin_round(i: int) -> void:
	_round = i
	_stage = Stage.INTRO
	_stage_time = 0.0
	var w: Array = ROUNDS[i]["wind"]
	_wind = _rng.randf_range(w[0], w[1]) * (1.0 if _rng.randf() < 0.5 else -1.0)
	var dist := float(ROUNDS[i]["dist"])
	for p: Player in players.values():
		var s := _archer(p)
		_clear_arrows(s)
		s.arrows_left = ARROWS
		s.drawing = false
		s.draw_t = 0.0
		s.wait_t = 0.0
		s.aim = Vector3.FORWARD
		s.bot_aim = Vector3.FORWARD
		s.target.position.z = -dist
		s.flag.position.z = -dist + 0.5
		s.bot_wait = 1.0 + p.c.player * 0.3
		_send_round_ui(p)


func _send_round_ui(p: Player) -> void:
	var s := _archer(p)
	send_ui(p, {"clear": true, "title": "ARCHERY R%d" % (_round + 1), "main": str(p.score),
		"sub": "%dm  %d LEFT" % [int(ROUNDS[_round]["dist"]), s.arrows_left], "legends": ["DRAW", "", "", null]})


func _capture_aim(p: Player) -> void:
	var s := _archer(p)
	s.aim_ref = p.c.motion_orientation()
	s.aim = Vector3.FORWARD


func _play_started() -> void:
	# Round 1's banner is the countdown: capture aim as it ends.
	_stage = Stage.SHOOT
	_stage_time = 0.0
	for p: Player in players.values():
		_capture_aim(p)


func _player_recentered(p: Player) -> void:
	_capture_aim(p)
	p.popup(tr("已重新对准"))


func _countdown_process(delta: float) -> void:
	for p: Player in players.values():
		_update_view(p, delta)


func _play_process(delta: float) -> void:
	_stage_time += delta
	for p: Player in players.values():
		var s := _archer(p)
		if _stage == Stage.SHOOT and s.arrows_left > 0 and not _arrow_in_flight(s):
			s.wait_t += delta
			_expire_arrow(p)
		if p.fake:
			_bot(p, delta)
		if s.drawing:
			s.draw_t += delta
			_update_power_ui(p)
		_fly_arrows(p, delta)
		_update_view(p, delta)
	match _stage:
		Stage.INTRO:
			if _stage_time >= INTRO_TIME:
				_stage = Stage.SHOOT
				_stage_time = 0.0
				for p: Player in players.values():
					_capture_aim(p)
		Stage.SHOOT:
			var done := true
			for p: Player in players.values():
				var s := _archer(p)
				done = done and s.arrows_left == 0 and not _arrow_in_flight(s)
			if done and _stage_time > 0.5:
				_stage = Stage.SUMMARY
				_stage_time = 0.0
				for p: Player in players.values():
					var total := 0
					for h in _archer(p).hits:
						total += int(h.z)
					_archer(p).round_scores.append(total)
		Stage.SUMMARY:
			if _stage_time >= SUMMARY_TIME:
				if _round + 1 < ROUNDS.size():
					_begin_round(_round + 1)
				else:
					finish_round()


func _results_process(delta: float) -> void:
	for p: Player in players.values():
		_fly_arrows(p, delta)


func _result_detail(p: Player) -> String:
	var s := _archer(p)
	var rounds := PackedStringArray()
	for v in s.round_scores:
		rounds.append(str(v))
	return tr("每轮 %s   10 环 ×%d") % [" / ".join(rounds), s.tens]


func _player_button(p: Player, button: int, pressed: bool) -> void:
	if button != RSController.BTN_A:
		return
	if pressed:
		_start_draw(p)
	else:
		_release(p)


func _start_draw(p: Player) -> void:
	var s := _archer(p)
	if phase != Phase.PLAY or _stage != Stage.SHOOT or s.arrows_left <= 0 or _arrow_in_flight(s):
		return
	if s.wait_t >= SHOT_WAIT:
		_expire_arrow(p)
		return
	s.drawing = true
	s.draw_t = 0.0


func _release(p: Player) -> void:
	var s := _archer(p)
	if not s.drawing:
		return
	if s.wait_t >= SHOT_WAIT:
		_expire_arrow(p)
		return
	var power := s.power()
	s.drawing = false
	send_ui(p, {"bar": null})
	if power < MIN_POWER:
		return
	var a := Arrow.new()
	a.node = _make_arrow(color_of(p))
	a.node.position = p.cam.position + s.aim * 0.5 + p.cam.basis * Vector3(-0.1, -0.1, 0)
	a.vel = s.aim * lerpf(SPEED_MIN, SPEED_MAX, power)
	add_child(a.node)
	a.node.look_at(a.node.position + a.vel)
	s.arrows.append(a)
	s.arrows_left -= 1
	s.wait_t = 0.0
	p.cam.fov += 4.0   # little kick
	haptic(p, "tap")


func _expire_arrow(p: Player) -> void:
	var s := _archer(p)
	if phase != Phase.PLAY or _stage != Stage.SHOOT or s.arrows_left <= 0 or _arrow_in_flight(s) or s.wait_t < SHOT_WAIT:
		return
	s.drawing = false
	s.draw_t = 0.0
	s.wait_t = 0.0
	s.arrows_left -= 1
	send_ui(p, {"bar": null})
	_score_arrow(p, Vector2(INF, INF), true)


func _update_power_ui(p: Player) -> void:
	var pct := int(_archer(p).power() * 10.0) * 10
	var key := "bar%d" % pct
	if key != p.oled_key:
		p.oled_key = key
		send_ui(p, {"bar": {"pct": pct, "label": "POWER"}})


func _fly_arrows(p: Player, dt: float) -> void:
	var s := _archer(p)
	for a in s.arrows:
		if not a.flying:
			continue
		a.age += dt
		var prev := a.node.position
		a.vel += (Vector3(_wind * WIND_ACCEL, 0.0, 0.0) + Vector3.DOWN * GRAVITY) * dt
		var pos := prev + a.vel * dt
		a.node.position = pos
		a.node.look_at(pos + a.vel)
		# Target face plane, crossing from the front.
		var tz := s.target.position.z
		if prev.z > tz and pos.z <= tz:
			var hit := prev.lerp(pos, (prev.z - tz) / (prev.z - pos.z))
			var off := Vector2(hit.x - s.lane_x, hit.y - FACE_Y)
			if off.length() <= BOSS_RADIUS:
				a.node.position = hit + a.vel.normalized() * 0.25
				a.flying = false
				_score_arrow(p, off)
				continue
		if pos.y <= 0.02:
			a.node.position.y = 0.05
			a.flying = false
			_score_arrow(p, Vector2(INF, INF))
		elif a.age > 4.0:
			a.node.visible = false
			a.flying = false
			_score_arrow(p, Vector2(INF, INF))


func _score_arrow(p: Player, off: Vector2, timed_out: bool = false) -> void:
	var s := _archer(p)
	var r := off.length()
	var ring := 0 if r > FACE_RADIUS else clampi(10 - int(r / (FACE_RADIUS / 10.0)), 1, 10)
	if r <= BOSS_RADIUS:
		s.hits.append(Vector3(off.x, off.y, ring))
	else:
		s.hits.append(Vector3(INF, INF, 0))
	p.score += ring
	if timed_out:
		p.popup(tr("出手超时，按 0 环计"), RSUi.TEXT_MUTED)
		toast(p, "TIME OUT", 600)
	elif ring == 10:
		s.tens += 1
		p.popup(tr("10 环！正中靶心"), Color(1.0, 0.85, 0.3))
		toast(p, "10!", 800)
		haptic(p, "great")
	elif ring > 0:
		p.popup(tr("%d 环") % ring, Color.WHITE)
		toast(p, str(ring), 600)
		haptic(p, "hit")
	else:
		p.popup(tr("脱靶"), Color(1.0, 0.65, 0.55))
		toast(p, "MISS", 600)
	p.oled_key = ""
	_send_round_ui(p)


func _update_view(p: Player, dt: float) -> void:
	var s := _archer(p)
	if not p.fake and p.c.connected and phase == Phase.PLAY and _stage == Stage.SHOOT:
		# Relative aim: how the controller turned since capture, applied to "straight ahead".
		var raw := (p.c.motion_orientation() * s.aim_ref.inverse()) * Vector3.FORWARD
		s.aim = s.aim.slerp(_clamp_aim(raw), 1.0 - exp(-dt * 18.0))
	elif p.fake:
		s.aim = s.aim.slerp(_clamp_aim(s.bot_aim), 1.0 - exp(-dt * 8.0))
	# Arms tire after holding full draw for a while.
	if s.drawing and s.draw_t > 3.0:
		var a := minf(s.draw_t - 3.0, 2.0) * 0.006
		s.aim = (s.aim + Vector3(sin(_clock * 7.0) * a, sin(_clock * 5.3) * a, 0.0)).normalized()
	p.cam.position = Vector3(s.lane_x, EYE.y, EYE.z)
	p.cam.look_at(p.cam.position + s.aim)
	var zoom := 1.0 - 0.45 * s.power() * (0.6 + 0.4 * _round / 2.0)
	p.cam.fov = lerpf(p.cam.fov, 55.0 * zoom, 1.0 - exp(-dt * 8.0))
	_pose_bow(s)
	var pennant := s.flag.get_node("Pennant") as Node3D
	var target_angle := 0.0 if absf(_wind) < 0.1 else (0.0 if _wind > 0.0 else PI)
	pennant.rotation.y = lerp_angle(pennant.rotation.y, target_angle + sin(_clock * 3.0) * 0.15 * absf(_wind), 0.1)
	pennant.rotation.z = lerpf(pennant.rotation.z, -1.3 + clampf(absf(_wind) / 3.0, 0.0, 1.0) * 1.2, 0.05)


func _clamp_aim(v: Vector3) -> Vector3:
	var yaw := clampf(atan2(-v.x, -v.z), -MAX_YAW, MAX_YAW)
	var pitch := clampf(asin(clampf(v.y, -1.0, 1.0)), -MAX_PITCH * 0.4, MAX_PITCH)
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


func _bot(p: Player, dt: float) -> void:
	## Bot archer: aim at the centre with drop and wind allowance plus some error, draw, shoot.
	var s := _archer(p)
	if _stage != Stage.SHOOT or s.arrows_left <= 0 or _arrow_in_flight(s):
		return
	if not s.drawing:
		s.bot_wait -= dt
		if s.bot_wait <= 0.0:
			var dist := float(ROUNDS[_round]["dist"])
			var t := dist / SPEED_MAX
			var spot := Vector3(s.lane_x - 0.5 * _wind * WIND_ACCEL * t * t, FACE_Y + 0.5 * GRAVITY * t * t, -dist)
			spot += Vector3(_rng.randf_range(-0.35, 0.35), _rng.randf_range(-0.35, 0.35), 0.0) * (1.0 + _round * 0.5) * bot_error()
			s.bot_aim = (spot - p.cam.position).normalized()
			s.drawing = true
			s.draw_t = 0.0
	elif s.draw_t > 1.4:
		_release(p)
		s.bot_wait = 1.0


# ---------------------------------------------------------------------------- HUD ----

func _draw_hud(h: PlayerHud, p: Player, k: float) -> void:
	var s := _archer(p)
	var sz := h.size
	var col := color_of(p)
	draw_text(h, tr("第 %d / %d 轮　%d 米") % [_round + 1, ROUNDS.size(), int(ROUNDS[_round]["dist"])], Vector2(20, 88) * k, 20 * k, Color(0.92, 0.95, 1.0))
	# Arrows left.
	for i in ARROWS:
		var x := (24 + i * 18) * k
		var c := Color(1, 1, 1, 0.9) if i < s.arrows_left else Color(1, 1, 1, 0.2)
		h.draw_line(Vector2(x, 100 * k), Vector2(x, 128 * k), c, 3.0 * k)
		h.draw_colored_polygon(PackedVector2Array([Vector2(x, 96 * k), Vector2(x - 4 * k, 104 * k), Vector2(x + 4 * k, 104 * k)]), c)
	# Wind, top right.
	var wind_text := tr("无风") if absf(_wind) < 0.1 else tr("风 %.1f m/s") % absf(_wind)
	draw_text(h, wind_text, Vector2(sz.x - 110 * k, 44 * k), 20 * k, Color.WHITE, true)
	if absf(_wind) >= 0.1:
		var c := Vector2(sz.x - 110 * k, 62 * k)
		var d := signf(_wind) * minf(absf(_wind) / 3.2, 1.0) * 40 * k + signf(_wind) * 10 * k
		h.draw_line(c - Vector2(d, 0), c + Vector2(d, 0), Color(0.75, 0.9, 1.0), 4 * k)
		h.draw_colored_polygon(PackedVector2Array([c + Vector2(d + signf(_wind) * 10 * k, 0), c + Vector2(d, -7 * k), c + Vector2(d, 7 * k)]), Color(0.75, 0.9, 1.0))

	# Reticle: tightens and fills an arc as the bow is drawn.
	if phase == Phase.PLAY and _stage == Stage.SHOOT and s.arrows_left > 0:
		var c := sz * 0.5
		var pw := s.power()
		var r := lerpf(28.0, 12.0, pw) * k
		var rc := col.lightened(0.4) if pw >= 1.0 else Color(1, 1, 1, 0.9)
		h.draw_arc(c, r, 0, TAU, 40, Color(0, 0, 0, 0.35), 4.0 * k, true)
		h.draw_arc(c, r, 0, TAU, 40, rc, 2.0 * k, true)
		for dir in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
			h.draw_line(c + dir * (r + 3 * k), c + dir * (r + 12 * k), rc, 2.0 * k)
		h.draw_circle(c, 2.0 * k, rc)
		if s.drawing:
			h.draw_arc(c, r + 18 * k, -PI / 2.0, -PI / 2.0 + TAU * pw, 48, col.lightened(0.2), 5.0 * k, true)
		elif s.arrows_left == ARROWS and _round == 0:
			draw_text(h, tr("按住 A 拉弓，松开放箭"), Vector2(c.x, sz.y * 0.61), 22 * k, Color.WHITE, true)

	# This round's arrows on a small target face, bottom right.
	if phase == Phase.PLAY and _stage == Stage.SHOOT and s.arrows_left > 0 and not _arrow_in_flight(s):
		draw_text(h, tr("出手剩余 %d 秒") % maxi(0, ceili(SHOT_WAIT - s.wait_t)), Vector2(20 * k, sz.y - 32 * k), 18 * k, RSUi.TEXT_MUTED)
	var fc := Vector2(sz.x - 80 * k, sz.y - 80 * k)
	var fr := 58.0 * k
	h.draw_circle(fc, fr * BOSS_RADIUS / FACE_RADIUS, Color(0.86, 0.76, 0.5, 0.85))
	for i in FACE_COLORS.size():
		h.draw_circle(fc, fr * (1.0 - i * 0.2), FACE_COLORS[i])
	for i in s.hits.size():
		var hit := s.hits[i]
		if is_inf(hit.x):
			continue
		var at := fc + Vector2(hit.x, -hit.y) / FACE_RADIUS * fr
		var last := i == s.hits.size() - 1
		h.draw_circle(at, (6.0 if last else 4.5) * k, Color.BLACK)
		h.draw_circle(at, (4.0 if last else 3.0) * k, col.lightened(0.3) if last else Color.WHITE)
	var round_total := 0
	for hit in s.hits:
		round_total += int(hit.z)
	draw_text(h, tr("本轮 %d") % round_total, fc + Vector2(0, -fr * 1.3 - 8 * k), 18 * k, Color.WHITE, true)


func _draw_overlay(o: Overlay, k: float) -> void:
	var c := o.size * 0.5
	if phase == Phase.COUNTDOWN:
		draw_text(o, tr("举起手柄，对准屏幕"), Vector2(c.x, c.y + 60 * k), 26 * k, Color(0.92, 0.95, 1.0), true)
		return
	if phase != Phase.PLAY:
		return
	if _stage == Stage.INTRO:
		draw_pill(o, tr("第 %d 轮　%d 米") % [_round + 1, int(ROUNDS[_round]["dist"])], c - Vector2(0, 30 * k), 56 * k)
		var hint := tr("举起手柄，对准屏幕") + (tr("　　有风，注意风向") if absf(_wind) >= 0.1 else "")
		draw_text(o, hint, c + Vector2(0, 50 * k), 26 * k, Color.WHITE, true)
	elif _stage == Stage.SUMMARY:
		draw_pill(o, tr("第 %d 轮结束") % (_round + 1), c - Vector2(0, 70 * k), 44 * k)
		var y := c.y + 10 * k
		for p: Player in ordered():
			var s := _archer(p)
			var v: int = s.round_scores[-1] if not s.round_scores.is_empty() else 0
			draw_pill(o, tr("P%d　本轮 %d　总分 %d") % [p.c.player, v, p.score], Vector2(c.x, y), 28 * k, color_of(p).lightened(0.45))
			y += 50 * k
