extends RSPartyGame
## 保龄球 (bowling, a P1 motion game): before the throw, tilt left/right to step across the
## approach; hold B and swing your arm like a real throw, let go of B to release. The peak
## swing speed sets the ball speed, how far the wrist is twisted (rolled) at release compared
## with when B went down sets the hook: twist right and the ball curves right late in the lane.
## Pins and ball are real rigid bodies. 5 frames (`-- --frames=N`), standard scoring incl.
## strike / spare bonuses and bonus balls in the last frame. Everyone bowls on their own lane.

const LANE_LEN := 18.29            ## foul line to the head pin
const LANE_HALF := 0.525
const GUTTER := 0.235
const LANE_SPACING := 2.6
const PIN_SPACING := 0.3048
const PIN_ROW := 0.264
const BALL_R := 0.109
const MAX_STEP := 0.42             ## how far the bowler can stand off centre
const SPEED_MIN := 3.0             ## m/s
const SPEED_MAX := 11.0
const HOOK_MAX := 1.6              ## lateral m/s^2 at full twist
const TWIST_FULL := 0.9            ## rad of wrist roll for full hook (~50 deg)
const TWIST_DEAD := 0.08
const SETTLE := 2.2                ## seconds after the ball is gone before counting pins

enum Step { AIM, SWING, ROLLING, SETTLE_PINS, DONE }


class Bowler:
	var lane_x := 0.0
	var stick := RSTiltStick.new()
	var step := Step.AIM
	var step_t := 0.0
	var pos := 0.0                  ## standing offset across the approach
	var ball: RigidBody3D
	var pins: Array[RigidBody3D] = []
	var standing: Array[bool] = []  ## pins up before this ball
	var frame := 0
	var ball_in_frame := 0
	var rolls: Array[int] = []
	var strikes := 0
	var spares := 0
	var hook := 0.0                 ## m/s^2, + = to the right
	var gutter := false
	var swing_q := Quaternion.IDENTITY
	var swing_roll := 0.0
	var peak_rate := 0.0
	var swing_angle := 0.0          ## for drawing the arm swing
	var release_twist := 0.0
	var bot_plan := Vector3.ZERO    ## (pos, speed, twist)
	var look := Vector3.ZERO        ## smoothed camera look-at point


var _frames := 5
var _rng := RandomNumberGenerator.new()
var _pin_mesh: Mesh
var _pin_mat: ShaderMaterial
var _lobby_t := 0.0
var _all_done_t := -1.0


func _game_name() -> String:
	return tr("保龄球")


func _oled_name() -> String:
	return "BOWLING"


func _how_to_play() -> String:
	return (tr("出球前左右倾斜手柄 = 左右挪动站位\n") +
		tr("按住 B 像真的扔球一样挥臂，松开 B 出球：挥得越快球越快；松手时手腕往右拧，球就往右拐（往左同理）\n") +
		tr("每局 %d 格，全中、补中有奖励分。按 A 准备时的拿法就是“端正”，长按 D 1 秒可以重新设定。") % _frames)


func _parse_arg(arg: String) -> void:
	if arg.begins_with("--frames="):
		_frames = clampi(int(arg.get_slice("=", 1)), 1, 10)


func _bowler(p: Player) -> Bowler:
	return p.data


# --------------------------------------------------------------------------- world ----

func _setup_world() -> void:
	_rng.seed = 9
	shot_times = [0.5, 2.5, 6.0, 7.5, 9.0, 20.0, 40.0, 70.0]
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.08, 0.09, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.72, 0.85)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.ssao_enabled = true
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.08
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.15
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-60, 20, 0)
	key.light_energy = 0.8
	key.shadow_enabled = true
	key.directional_shadow_max_distance = 40.0
	add_child(key)
	for z in [2.0, -6.0, -14.0, -19.0]:
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(0, 3.2, z)
		lamp.omni_range = 14.0
		lamp.light_energy = 1.2
		lamp.light_color = Color(1.0, 0.92, 0.8)
		add_child(lamp)

	# Floor, back wall, ceiling strip of neon.
	var floor_mi := MeshInstance3D.new()
	var fm := PlaneMesh.new()
	fm.size = Vector2(40, 40)
	floor_mi.mesh = fm
	floor_mi.material_override = RSMeshUtil.toon_material(Color(0.22, 0.2, 0.32), 0.0, 0.9)
	floor_mi.position = Vector3(0, -0.6, -8)
	add_child(floor_mi)
	var wall := MeshInstance3D.new()
	wall.mesh = RSMeshUtil.rounded_box(Vector3(16, 6, 0.4), 0.1)
	wall.material_override = RSMeshUtil.toon_material(Color(0.16, 0.15, 0.28), 0.1)
	wall.position = Vector3(0, 2.2, -21.0)
	add_child(wall)
	var neon_colors := [Color(1.0, 0.3, 0.7), Color(0.3, 0.8, 1.0)]
	for i in 2:
		var neon := MeshInstance3D.new()
		neon.mesh = RSMeshUtil.rounded_box(Vector3(15.5, 0.08, 0.08), 0.03)
		var nm := StandardMaterial3D.new()
		nm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		nm.albedo_color = neon_colors[i] * 1.6
		neon.material_override = nm
		neon.position = Vector3(0, 4.4 + i * 0.3, -20.75)
		add_child(neon)

	_pin_mesh = _lathe_pin()
	_pin_mat = RSMeshUtil.toon_material(Color.WHITE, 0.35, 0.3)
	_pin_mat.set_shader_parameter("use_vertex_color", true)
	for i in 4:
		_build_lane(_lane_x(i + 1), i + 1)
	lobby_cam.fov = 50
	lobby_cam.far = 200


func _lane_x(player: int) -> float:
	return (player - 2.5) * LANE_SPACING


func _static_box(size: Vector3, pos: Vector3, mat: Material, friction: float = 0.3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.position = pos
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	var pm := PhysicsMaterial.new()
	pm.friction = friction
	body.physics_material_override = pm
	if mat:
		var mi := MeshInstance3D.new()
		mi.mesh = RSMeshUtil.rounded_box(size, minf(0.02, size.y * 0.4))
		mi.material_override = mat
		body.add_child(mi)
	add_child(body)
	return body


func _build_lane(x0: float, player: int) -> void:
	var wood := RSMeshUtil.toon_material(Color(0.93, 0.76, 0.52), 0.25, 0.25)
	var wood_dark := RSMeshUtil.toon_material(Color(0.78, 0.58, 0.36), 0.2, 0.3)
	var gutter_mat := RSMeshUtil.toon_material(Color(0.25, 0.26, 0.3), 0.2, 0.4)
	var side_mat := RSMeshUtil.toon_material(Color(0.17, 0.16, 0.28), 0.25)
	var color: Color = RSControllerModel.PLAYER_COLORS[player]
	var glow := StandardMaterial3D.new()
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	glow.albedo_color = color * 1.4
	var deck_end := -LANE_LEN - 1.0
	var len := 4.5 - deck_end
	# Lane + approach (one slab), gutters a step lower, dividers between lanes.
	_static_box(Vector3(LANE_HALF * 2.0, 0.1, len), Vector3(x0, -0.05, 4.5 - len * 0.5), wood, 0.08)
	for sx in [-1.0, 1.0]:
		_static_box(Vector3(GUTTER, 0.1, len - 4.5), Vector3(x0 + sx * (LANE_HALF + GUTTER * 0.5), -0.15, deck_end * 0.5), gutter_mat)
		_static_box(Vector3(LANE_SPACING * 0.5 - LANE_HALF - GUTTER, 0.32, len), Vector3(x0 + sx * (LANE_SPACING * 0.5 - (LANE_SPACING * 0.5 - LANE_HALF - GUTTER) * 0.5), 0.06, 4.5 - len * 0.5), side_mat)
	# Glowing strips in the player's colour along both outer gutter edges.
	for sx in [-1.0, 1.0]:
		var strip := MeshInstance3D.new()
		strip.mesh = RSMeshUtil.rounded_box(Vector3(0.03, 0.02, len - 4.5), 0.01)
		strip.material_override = glow
		strip.position = Vector3(x0 + sx * (LANE_HALF + GUTTER + 0.02), 0.225, deck_end * 0.5)
		add_child(strip)
	# Pit floor and cushion behind the pins.
	_static_box(Vector3(LANE_SPACING, 0.1, 1.6), Vector3(x0, -0.55, deck_end - 0.8), gutter_mat, 0.8)
	_static_box(Vector3(LANE_SPACING, 1.4, 0.2), Vector3(x0, 0.1, deck_end - 1.6), RSMeshUtil.toon_material(Color(0.1, 0.1, 0.12), 0.0), 0.9)
	# Foul line, target arrows and dots.
	var foul := MeshInstance3D.new()
	foul.mesh = RSMeshUtil.rounded_box(Vector3(LANE_HALF * 2.0, 0.005, 0.03), 0.002)
	foul.material_override = RSMeshUtil.toon_material(Color(0.2, 0.2, 0.25), 0.0)
	foul.position = Vector3(x0, 0.003, 0)
	add_child(foul)
	var tri := PrismMesh.new()
	tri.size = Vector3(0.05, 0.16, 0.004)
	for k in 7:
		var arrow := MeshInstance3D.new()
		arrow.mesh = tri
		arrow.material_override = wood_dark
		arrow.rotation.x = -PI / 2.0
		arrow.position = Vector3(x0 + (k - 3) * 0.13, 0.003, -4.6 - absi(k - 3) * 0.3)
		add_child(arrow)
	# Masking panel above the pins in the player's colour, with the lane number.
	var panel := MeshInstance3D.new()
	panel.mesh = RSMeshUtil.rounded_box(Vector3(LANE_SPACING - 0.1, 0.9, 0.12), 0.08)
	panel.material_override = RSMeshUtil.toon_material(color, 0.4)
	panel.position = Vector3(x0, 1.45, deck_end - 0.4)
	add_child(panel)
	var label := Label3D.new()
	label.text = "P%d" % player
	label.font = font
	label.font_size = 96
	label.pixel_size = 0.006
	label.outline_size = 16
	label.position = Vector3(x0, 1.45, deck_end - 0.33)
	add_child(label)


func _lathe_pin() -> ArrayMesh:
	## Turned pin profile (radius, height) in metres, with the two red neck stripes.
	var prof := [[0.026, 0.0], [0.042, 0.012], [0.056, 0.05], [0.0605, 0.115], [0.056, 0.17], [0.038, 0.232],
		[0.024, 0.262], [0.021, 0.285], [0.026, 0.318], [0.031, 0.345], [0.027, 0.368], [0.015, 0.379], [0.0, 0.381]]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 20
	for i in prof.size() - 1:
		var a: Array = prof[i]
		var b: Array = prof[i + 1]
		var mid_y := (float(a[1]) + float(b[1])) * 0.5
		var red := (mid_y > 0.245 and mid_y < 0.27) or (mid_y > 0.288 and mid_y < 0.302)
		var col := (Color(0.85, 0.1, 0.12) if red else Color(0.97, 0.97, 0.95)).srgb_to_linear()
		for k in seg:
			var t0 := TAU * k / seg
			var t1 := TAU * (k + 1) / seg
			var p00 := Vector3(cos(t0) * a[0], a[1], sin(t0) * a[0])
			var p01 := Vector3(cos(t1) * a[0], a[1], sin(t1) * a[0])
			var p10 := Vector3(cos(t0) * b[0], b[1], sin(t0) * b[0])
			var p11 := Vector3(cos(t1) * b[0], b[1], sin(t1) * b[0])
			for v in [p00, p10, p11, p00, p11, p01]:
				st.set_color(col)
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


func _make_pin() -> RigidBody3D:
	var pin := RigidBody3D.new()
	pin.mass = 1.5
	pin.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	pin.center_of_mass = Vector3(0, 0.14, 0)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.45
	pm.bounce = 0.35
	pin.physics_material_override = pm
	pin.continuous_cd = true
	var shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = 0.058
	cyl.height = 0.38
	shape.shape = cyl
	shape.position.y = 0.19
	pin.add_child(shape)
	var mi := MeshInstance3D.new()
	mi.mesh = _pin_mesh
	mi.material_override = _pin_mat
	pin.add_child(mi)
	return pin


func _make_ball(color: Color) -> RigidBody3D:
	var ball := RigidBody3D.new()
	ball.mass = 6.5
	var pm := PhysicsMaterial.new()
	pm.friction = 0.25
	pm.bounce = 0.05
	ball.physics_material_override = pm
	ball.continuous_cd = true
	ball.angular_damp = 0.0
	var shape := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = BALL_R
	shape.shape = sph
	ball.add_child(shape)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = BALL_R
	sm.height = BALL_R * 2.0
	mi.mesh = sm
	var mat := RSMeshUtil.toon_material(color, 0.6, 0.15)
	mat.set_shader_parameter("specular", 0.8)
	mi.material_override = mat
	ball.add_child(mi)
	# Finger holes, so the spin is visible.
	var hole := SphereMesh.new()
	hole.radius = 0.016
	hole.height = 0.032
	var dark := RSMeshUtil.toon_material(Color(0.05, 0.05, 0.07), 0.0)
	for off in [Vector3(-0.025, 0.1, -0.02), Vector3(0.025, 0.1, -0.02), Vector3(0.0, 0.095, 0.045)]:
		var h := MeshInstance3D.new()
		h.mesh = hole
		h.material_override = dark
		h.position = off
		ball.add_child(h)
	ball.freeze = true
	return ball


func _pin_spot(s: Bowler, i: int) -> Vector3:
	var row := 0
	var k := i
	while k > row:
		k -= row + 1
		row += 1
	return Vector3(s.lane_x + (k - row * 0.5) * PIN_SPACING, 0.001, -LANE_LEN - row * PIN_ROW)


func _lobby_process(delta: float) -> void:
	_lobby_t += delta
	lobby_cam.position = Vector3(sin(_lobby_t * 0.2) * 2.5, 2.6, 4.5)
	lobby_cam.look_at(Vector3(0, 0.3, -LANE_LEN))


# ------------------------------------------------------------------------ bowlers ----

func _player_added(p: Player) -> void:
	var s := Bowler.new()
	p.data = s
	s.lane_x = _lane_x(p.c.player)
	for i in 10:
		var pin := _make_pin()
		add_child(pin)
		s.pins.append(pin)
		s.standing.append(true)
	s.ball = _make_ball(color_of(p))
	add_child(s.ball)
	_reset_pins(s, true)
	_hold_ball(s)
	p.cam.fov = 50
	p.cam.far = 200
	_place_cam(p, 0.0, true)


func _player_removed(p: Player) -> void:
	var s := _bowler(p)
	for pin in s.pins:
		pin.queue_free()
	s.ball.queue_free()


func _player_ready(p: Player, is_ready: bool) -> void:
	if is_ready:
		_bowler(p).stick.capture(p.c.motion_orientation())


func _player_recentered(p: Player) -> void:
	_bowler(p).stick.capture(p.c.motion_orientation())
	p.popup(tr("已重新设定"))


func _reset_pins(s: Bowler, all: bool) -> void:
	## all: a fresh rack. Otherwise clear away the pins that went down.
	for i in 10:
		var pin := s.pins[i]
		if all:
			s.standing[i] = true
		pin.freeze = true
		pin.linear_velocity = Vector3.ZERO
		pin.angular_velocity = Vector3.ZERO
		if s.standing[i]:
			pin.global_transform = Transform3D(Basis.IDENTITY, _pin_spot(s, i))
			pin.visible = true
			pin.collision_layer = 1
			pin.collision_mask = 1
			pin.set_deferred("freeze", false)
		else:
			pin.visible = false
			pin.collision_layer = 0
			pin.collision_mask = 0
			pin.global_position = Vector3(s.lane_x, -5.0, 10.0)


func _hold_ball(s: Bowler) -> void:
	s.ball.freeze = true
	s.ball.linear_velocity = Vector3.ZERO
	s.ball.angular_velocity = Vector3.ZERO
	s.ball.visible = true
	s.ball.global_transform = Transform3D(Basis.IDENTITY, Vector3(s.lane_x + s.pos + 0.18, 0.75, 1.0))


func _pin_down(s: Bowler, i: int) -> bool:
	var pin := s.pins[i]
	var spot := _pin_spot(s, i)
	return pin.global_basis.y.dot(Vector3.UP) < 0.75 or pin.global_position.y < -0.05 \
		or Vector2(pin.global_position.x - spot.x, pin.global_position.z - spot.z).length() > 0.15


# ------------------------------------------------------------------------- rounds ----

func _round_started(list: Array) -> void:
	_all_done_t = -1.0
	for p: Player in list:
		var s := _bowler(p)
		s.frame = 0
		s.ball_in_frame = 0
		s.rolls.clear()
		s.strikes = 0
		s.spares = 0
		s.pos = 0.0
		s.step = Step.AIM
		s.step_t = 0.0
		s.bot_plan = Vector3.ZERO
		_reset_pins(s, true)
		_hold_ball(s)
		_place_cam(p, 0.0, true)
		_send_frame_ui(p)


func _send_frame_ui(p: Player) -> void:
	var s := _bowler(p)
	send_ui(p, {"clear": true, "title": "BOWLING F%d" % (mini(s.frame, _frames - 1) + 1), "main": str(p.score),
		"sub": "BALL %d" % (s.ball_in_frame + 1), "legends": ["", "SWING", "", null]})


func _countdown_process(delta: float) -> void:
	for p: Player in players.values():
		_place_cam(p, delta, false)


func _play_process(delta: float) -> void:
	var all_done := true
	for p: Player in players.values():
		var s := _bowler(p)
		s.step_t += delta
		if p.fake:
			_bot(p)
		match s.step:
			Step.AIM:
				var stick := s.stick.stick(p.c.motion_orientation()) if (p.c.connected and not p.fake) else Vector2.ZERO
				s.pos = clampf(s.pos + stick.x * 0.7 * delta, -MAX_STEP, MAX_STEP)
				_hold_ball(s)
			Step.SWING:
				_track_swing(p)
			Step.ROLLING:
				_watch_ball(p)
			Step.SETTLE_PINS:
				if s.step_t >= SETTLE:
					_count_pins(p)
		_place_cam(p, delta, false)
		all_done = all_done and s.step == Step.DONE
	if all_done:
		if _all_done_t < 0.0:
			_all_done_t = 0.0
		_all_done_t += delta
		if _all_done_t > 1.5:
			finish_round()


func _physics_process(_delta: float) -> void:
	if phase != Phase.PLAY:
		return
	for p: Player in players.values():
		var s := _bowler(p)
		if s.step != Step.ROLLING or s.gutter:
			continue
		# Skid first, hook in the back end: the lateral push grows from ~6 m to ~13 m.
		var travelled := -s.ball.global_position.z
		var amount := smoothstep(5.0, 13.0, travelled)
		if s.ball.global_position.y > 0.0 and travelled < LANE_LEN:
			s.ball.apply_central_force(Vector3(s.hook * amount * s.ball.mass, 0.0, 0.0))


func _results_process(delta: float) -> void:
	for p: Player in players.values():
		_place_cam(p, delta, false)


# -------------------------------------------------------------------------- throw ----

func _player_button(p: Player, button: int, pressed: bool) -> void:
	if button != RSController.BTN_B or phase != Phase.PLAY:
		return
	var s := _bowler(p)
	if pressed and s.step == Step.AIM:
		_start_swing(p)
	elif not pressed and s.step == Step.SWING:
		_release(p, _swing_speed(s.peak_rate), _twist(p))


func _start_swing(p: Player) -> void:
	var s := _bowler(p)
	s.step = Step.SWING
	s.step_t = 0.0
	s.swing_q = p.c.motion_orientation()
	s.swing_roll = p.c.motion_roll()
	s.peak_rate = 0.0
	s.swing_angle = 0.0


func _track_swing(p: Player) -> void:
	var s := _bowler(p)
	if p.fake:
		s.swing_angle = -1.2 * cos(s.step_t / 0.9 * PI)
	else:
		s.peak_rate = maxf(s.peak_rate, p.c.gyro.length())
		# The arm swings about the controller's own right axis (body X) for either grip.
		var r := s.swing_q.inverse() * p.c.motion_orientation()
		s.swing_angle = clampf(2.0 * atan2(r.x, r.w), -1.8, 1.8)
	var ball_at := Vector3(s.lane_x + s.pos + 0.18, 0.8, 0.6) + Vector3(0, -0.6 * cos(s.swing_angle), -0.6 * sin(s.swing_angle))
	s.ball.global_position = ball_at
	if s.step_t > 6.0 and not p.fake:
		_release(p, _swing_speed(s.peak_rate), _twist(p))   # held too long: let it go


func _swing_speed(peak: float) -> float:
	return clampf(remap(peak, 2.0, 10.0, 4.0, 10.0), SPEED_MIN, SPEED_MAX)


func _twist(p: Player) -> float:
	## Wrist roll since B went down, rad, + = rolled to the right.
	var s := _bowler(p)
	return wrapf(p.c.motion_roll() - s.swing_roll, -PI, PI)


func _release(p: Player, speed: float, twist: float) -> void:
	var s := _bowler(p)
	var t := signf(twist) * maxf(absf(twist) - TWIST_DEAD, 0.0) / (TWIST_FULL - TWIST_DEAD)
	s.hook = clampf(t, -1.0, 1.0) * HOOK_MAX
	s.release_twist = twist
	s.gutter = false
	s.step = Step.ROLLING
	s.step_t = 0.0
	s.ball.global_transform = Transform3D(Basis.IDENTITY, Vector3(s.lane_x + s.pos, BALL_R + 0.005, -0.3))
	s.ball.freeze = false
	s.ball.linear_velocity = Vector3(0, 0, -speed)
	s.ball.angular_velocity = Vector3(-speed / BALL_R, 0, -s.hook * 4.0)
	var curve := tr("直球") if absf(s.hook) < 0.1 else (tr("右旋") if s.hook > 0.0 else tr("左旋"))
	p.popup(tr("%d km/h　%s") % [roundi(speed * 3.6), curve], Color(0.85, 0.92, 1.0))
	haptic(p, "tap")


func _watch_ball(p: Player) -> void:
	var s := _bowler(p)
	var b := s.ball.global_position
	if not s.gutter and absf(b.x - s.lane_x) > LANE_HALF + 0.02 and b.z > -LANE_LEN + 0.3:
		s.gutter = true
		p.popup(tr("洗沟了"), Color(1.0, 0.65, 0.55))
	var gone := b.z < -LANE_LEN - 1.0 or b.y < -0.3
	var stopped := s.step_t > 1.0 and s.ball.linear_velocity.length() < 0.15
	if gone or stopped or s.step_t > 8.0:
		s.step = Step.SETTLE_PINS
		s.step_t = 0.0


func _count_pins(p: Player) -> void:
	var s := _bowler(p)
	var knocked := 0
	for i in 10:
		if s.standing[i] and _pin_down(s, i):
			s.standing[i] = false
			knocked += 1
	var first_ball := s.ball_in_frame == 0 or (s.frame == _frames - 1 and _fresh_rack_ball(s))
	s.rolls.append(knocked)
	var standing := s.standing.count(true)
	var label := tr("%d 瓶") % knocked
	var oled := "%d PINS" % knocked
	var reset_all := false
	var next_frame := false
	if standing == 0 and first_ball:
		s.strikes += 1
		label = tr("全中！STRIKE")
		oled = "STRIKE!"
		haptic(p, "great")
	elif standing == 0:
		s.spares += 1
		label = tr("补中！SPARE")
		oled = "SPARE!"
		haptic(p, "good")
	elif knocked == 0:
		label = tr("一个没中")
		oled = "MISS"
	p.popup(label, Color(1.0, 0.85, 0.3) if standing == 0 else Color.WHITE)
	toast(p, oled, 900)

	if s.frame < _frames - 1:
		next_frame = standing == 0 or s.ball_in_frame == 1
		s.ball_in_frame += 1
	else:
		# Last frame: a strike or spare earns bonus balls (up to 3 in total).
		s.ball_in_frame += 1
		var r := s.rolls.slice(s.rolls.size() - s.ball_in_frame)
		var earned: bool = r[0] == 10 or (r.size() >= 2 and r[0] + r[1] == 10)
		if s.ball_in_frame >= 3 or (s.ball_in_frame == 2 and not earned):
			s.step = Step.DONE
		elif standing == 0:
			reset_all = true
	p.score = _total(s.rolls)
	if s.step == Step.DONE:
		s.ball.visible = false
		send_ui(p, {"clear": true, "title": "BOWLING", "main": str(p.score), "sub": "DONE", "legends": ["", "", "", null]})
		return
	if next_frame:
		s.frame += 1
		s.ball_in_frame = 0
		reset_all = true
	_reset_pins(s, reset_all)
	s.step = Step.AIM
	s.step_t = 0.0
	s.bot_plan = Vector3.ZERO
	_hold_ball(s)
	_send_frame_ui(p)


func _fresh_rack_ball(s: Bowler) -> bool:
	## In the last frame, is this ball thrown at a full rack (after a strike or spare)?
	var r := s.rolls.slice(s.rolls.size() - s.ball_in_frame)
	if r.is_empty():
		return true
	if r.size() == 1:
		return r[0] == 10
	return (r[0] == 10 and r[1] == 10) or (r[0] != 10 and r[0] + r[1] == 10)


func _total(rolls: Array[int]) -> int:
	var cum := _cumulative(rolls)
	return cum[-1] if not cum.is_empty() else 0


func _cumulative(rolls: Array[int]) -> Array[int]:
	## Running total after each finished frame (frames whose bonus balls aren't thrown yet
	## are left out). The standard formula also covers the last frame's bonus balls.
	var out: Array[int] = []
	var i := 0
	var total := 0
	for f in _frames:
		if i >= rolls.size():
			break
		if rolls[i] == 10:
			if i + 2 >= rolls.size():
				break
			total += 10 + rolls[i + 1] + rolls[i + 2]
			i += 1
		else:
			if i + 1 >= rolls.size():
				break
			if rolls[i] + rolls[i + 1] == 10:
				if i + 2 >= rolls.size():
					break
				total += 10 + rolls[i + 2]
			else:
				total += rolls[i] + rolls[i + 1]
			i += 2
		out.append(total)
	return out


func _marks(s: Bowler) -> Array:
	## Scoreboard marks per frame: ["X"], ["7", "/"], ["9", "-"], last frame up to 3.
	var out := []
	var i := 0
	var rolls := s.rolls
	for f in _frames:
		var m := []
		if f < _frames - 1:
			if i >= rolls.size():
				out.append(m)
				continue
			if rolls[i] == 10:
				m.append("X")
				i += 1
			else:
				m.append(_digit(rolls[i]))
				if i + 1 < rolls.size():
					m.append("/" if rolls[i] + rolls[i + 1] == 10 else _digit(rolls[i + 1]))
				i += 2
		else:
			var r := rolls.slice(i)
			if r.size() >= 1:
				m.append("X" if r[0] == 10 else _digit(r[0]))
			if r.size() >= 2:
				if r[0] == 10:
					m.append("X" if r[1] == 10 else _digit(r[1]))
				else:
					m.append("/" if r[0] + r[1] == 10 else _digit(r[1]))
			if r.size() >= 3:
				var fresh: bool = r[1] == 10 or (r[0] != 10 and r[0] + r[1] == 10)
				if fresh:
					m.append("X" if r[2] == 10 else _digit(r[2]))
				else:
					m.append("/" if r[1] + r[2] == 10 else _digit(r[2]))
		out.append(m)
	return out


func _digit(v: int) -> String:
	return "-" if v == 0 else str(v)


func _result_detail(p: Player) -> String:
	var s := _bowler(p)
	return tr("全中 %d   补中 %d") % [s.strikes, s.spares]


func _bot(p: Player) -> void:
	## Bot bowler: pick a spot and a hook toward the pocket, swing for ~0.9 s, release.
	var s := _bowler(p)
	if s.step == Step.AIM:
		if s.bot_plan == Vector3.ZERO:
			var pos := _rng.randf_range(-0.3, 0.3)
			var twist := clampf(-pos * 1.6 + _rng.randf_range(-0.35, 0.35), -0.9, 0.9)
			if s.standing.count(true) < 10:
				# Spare ball: roll straight at the middle of what's left.
				var sum := 0.0
				for i in 10:
					if s.standing[i]:
						sum += _pin_spot(s, i).x - s.lane_x
				pos = clampf(sum / maxi(1, s.standing.count(true)) + _rng.randf_range(-0.08, 0.08), -MAX_STEP, MAX_STEP)
				twist = 0.0
			s.bot_plan = Vector3(pos, _rng.randf_range(7.0, 9.5), twist + 0.001)
		s.pos = move_toward(s.pos, s.bot_plan.x, 0.01)
		if s.step_t > 1.6:
			_start_swing(p)
	elif s.step == Step.SWING and s.step_t > 0.9:
		_release(p, s.bot_plan.y, s.bot_plan.z)


# --------------------------------------------------------------------------- view ----

func _place_cam(p: Player, dt: float, snap: bool) -> void:
	var s := _bowler(p)
	var want := Vector3(s.lane_x + s.pos * 0.5, 1.5, 3.2)
	var look := Vector3(s.lane_x, 0.2, -LANE_LEN * 0.6)
	if s.step in [Step.ROLLING, Step.SETTLE_PINS] or (s.step == Step.DONE and phase == Phase.PLAY):
		# Chase the ball, then hold a few metres in front of the pins.
		var bz := clampf(s.ball.global_position.z, -LANE_LEN + 4.5, 0.0) if s.step == Step.ROLLING else -LANE_LEN + 4.5
		want = Vector3(s.lane_x, 1.1, bz + 2.6)
		look = Vector3(s.lane_x, 0.15, -LANE_LEN - 0.2)
	var k := 1.0 if snap else 1.0 - exp(-dt * 4.0)
	p.cam.position = p.cam.position.lerp(want, k)
	s.look = s.look.lerp(look, k)
	p.cam.look_at(s.look)


# ---------------------------------------------------------------------------- HUD ----

func _draw_hud(h: PlayerHud, p: Player, k: float) -> void:
	var s := _bowler(p)
	var sz := h.size
	var col := color_of(p)
	# Scoreboard: marks on top, running total below.
	var marks := _marks(s)
	var cum := _cumulative(s.rolls)
	var box := Vector2(52, 50) * k
	var x0 := 20 * k
	var y0 := 72 * k
	var x := x0
	for f in _frames:
		var r := Rect2(Vector2(x, y0), Vector2(box.x * (1.4 if f == _frames - 1 else 1.0), box.y))
		x += r.size.x
		var cur := f == s.frame and s.step != Step.DONE
		h.draw_rect(r, Color(0.05, 0.06, 0.1, 0.65))
		h.draw_rect(r, col.lightened(0.3) if cur else Color(1, 1, 1, 0.35), false, (2.5 if cur else 1.0) * k)
		var m: Array = marks[f]
		for j in m.size():
			var mx := r.end.x - (m.size() - j - 0.5) * 15 * k
			draw_text(h, m[j], Vector2(mx, y0 + 18 * k), 15 * k, Color(1.0, 0.85, 0.3) if m[j] in ["X", "/"] else Color.WHITE, true)
		if f < cum.size():
			draw_text(h, str(cum[f]), Vector2(r.get_center().x, y0 + 43 * k), 18 * k, Color.WHITE, true)
		draw_text(h, str(f + 1), Vector2(r.position.x + 9 * k, y0 + 13 * k), 10 * k, Color(1, 1, 1, 0.5), true)

	match s.step:
		Step.AIM:
			if phase == Phase.PLAY:
				draw_text(h, tr("左右倾斜挪位置　按住 B 挥臂，松开出球"), Vector2(sz.x * 0.5, sz.y - 40 * k), 22 * k, Color.WHITE, true)
				var label := tr("第 %d 格　第 %d 球") % [mini(s.frame, _frames - 1) + 1, s.ball_in_frame + 1]
				draw_text(h, label, Vector2(sz.x * 0.5, sz.y - 76 * k), 20 * k, Color(0.85, 0.9, 1.0), true)
		Step.SWING:
			# Live twist gauge: where the ball would curve if released now.
			var tw := 0.0 if p.fake else _twist(p)
			var t := clampf(tw / TWIST_FULL, -1.0, 1.0)
			var c := Vector2(sz.x * 0.5, sz.y - 70 * k)
			var w := 150 * k
			h.draw_rect(Rect2(c - Vector2(w, 6 * k), Vector2(w * 2.0, 12 * k)), Color(0, 0, 0, 0.4))
			h.draw_circle(c + Vector2(t * w, 0), 11 * k, col.lightened(0.3))
			draw_text(h, tr("左旋"), c + Vector2(-w - 30 * k, 7 * k), 18 * k, Color.WHITE, true)
			draw_text(h, tr("右旋"), c + Vector2(w + 30 * k, 7 * k), 18 * k, Color.WHITE, true)
			draw_text(h, tr("挥臂中……松开 B 出球"), c + Vector2(0, -24 * k), 22 * k, Color.WHITE, true)
		Step.DONE:
			if phase == Phase.PLAY:
				draw_text(h, tr("打完了，等其他玩家"), Vector2(sz.x * 0.5, sz.y * 0.6), 26 * k, Color.WHITE, true)


func _draw_overlay(o: Overlay, k: float) -> void:
	if phase == Phase.COUNTDOWN:
		draw_text(o, tr("像真的扔保龄球一样挥臂"), Vector2(o.size.x * 0.5, o.size.y * 0.45 + 60 * k), 26 * k, Color(0.92, 0.95, 1.0), true)
