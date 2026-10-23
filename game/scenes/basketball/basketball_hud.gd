class_name RSBasketballHud
extends RefCounted
## Basketball HUD and replay overlays. Gameplay state remains owned by the game.


static func power_meter_rect(size: Vector2, k: float) -> Rect2:
	return Rect2(Vector2(size.x - 54 * k, size.y * 0.28), Vector2(16 * k, size.y * 0.4))


static func draw_hud(game: RSBasketballGame, h: RSPartyGame.PlayerHud, p: RSPartyGame.Player, k: float) -> void:
	var s := game._sh(p)
	var sz := h.size
	if game.phase == RSBasketballGame.Phase.RESULTS:
		draw_replay(game, h, p, k)
		return
	if game.phase == RSBasketballGame.Phase.COUNTDOWN and game.phase_time < RSBasketballGame.INTRO:
		return
	var pale := Color(0.92, 0.95, 1.0)

	# Racks: five groups of five along the bottom, money balls ringed in gold.
	var dot := 9.0 * k
	var gap := 6.0 * k
	var group := RSBasketballGame.BALLS * (dot * 2.0 + gap) + 14.0 * k
	var w := group * RSBasketballGame.RACKS
	var x0 := sz.x * 0.5 - w * 0.5
	var y := sz.y - 30.0 * k
	game._pill.set_corner_radius_all(int(14 * k))
	h.draw_style_box(game._pill, Rect2(Vector2(x0 - 12 * k, y - 20 * k), Vector2(w + 10 * k, 40 * k)))
	for r in RSBasketballGame.RACKS:
		for b in RSBasketballGame.BALLS:
			var at := Vector2(x0 + r * group + b * (dot * 2.0 + gap) + dot, y)
			var res: int = s.results[r][b] if s.results.size() > r else 0
			var current := r == s.rack and b == s.ball_i and s.st != RSBasketballGame.St.DONE
			var col := Color(1, 1, 1, 0.18)
			match res:
				1:
					col = Color(0.95, 0.45, 0.12)
				2:
					col = Color(1.0, 0.6, 0.15)
				3:
					col = Color(0.3, 0.32, 0.36)
			var rad := dot * (1.15 if b == RSBasketballGame.BALLS - 1 else 1.0)
			if current:
				rad *= 1.0 + 0.15 * sin(game._clock * 8.0)
			h.draw_circle(at, rad, col)
			if b == RSBasketballGame.BALLS - 1:
				h.draw_arc(at, rad + 1.5 * k, 0, TAU, 20, RSBasketballGame.GOLD, 2.0 * k, true)
			elif current:
				h.draw_arc(at, rad + 1.5 * k, 0, TAU, 20, Color.WHITE, 2.0 * k, true)
			if res == 2:
				h.draw_arc(at, rad * 0.55, 0, TAU, 16, Color.WHITE, 1.6 * k, true)
			elif res == 3:
				h.draw_line(at + Vector2(-0.5, -0.5) * rad, at + Vector2(0.5, 0.5) * rad, Color(0.8, 0.82, 0.86), 2.0 * k)
				h.draw_line(at + Vector2(-0.5, 0.5) * rad, at + Vector2(0.5, -0.5) * rad, Color(0.8, 0.82, 0.86), 2.0 * k)

	# Shooting and streak under the score.
	h.draw_style_box(game._pill, Rect2(Vector2(12, 68) * k, Vector2(170, 54) * k))
	game.draw_text(h, game.tr("命中 %d/%d") % [s.made, s.shots], Vector2(22 * k, 88 * k), 19 * k, pale)
	if s.fire:
		var f := 0.75 + 0.25 * sin(game._clock * 10.0)
		game.draw_text(h, game.tr("火热 ×1.5  连中 %d") % s.streak, Vector2(22 * k, 114 * k), 19 * k, Color(RSBasketballGame.FIRE_COL, f))
	else:
		game.draw_text(h, game.tr("连中 %d") % s.streak, Vector2(22 * k, 114 * k), 19 * k, pale if s.streak > 0 else Color(pale, 0.6))

	# Power meter after each shot: where the flick landed against the sweet spot.
	var age := game._clock - s.meter_t
	if age < 1.8:
		var a := clampf((1.8 - age) / 0.4, 0.0, 1.0)
		var bar := power_meter_rect(sz, k)
		h.draw_style_box(game._pill, Rect2(bar.position - Vector2(16, 34) * k, bar.size + Vector2(32, 60) * k))
		var span := 0.8
		var ycol := func(e: float) -> float: return bar.end.y - bar.size.y * clampf((e + span) / (span * 2.0), 0.0, 1.0)
		h.draw_rect(bar, Color(0.85, 0.3, 0.25, 0.7 * a))
		h.draw_rect(Rect2(Vector2(bar.position.x, ycol.call(0.3)), Vector2(bar.size.x, ycol.call(-0.3) - ycol.call(0.3))), Color(1.0, 0.8, 0.25, 0.85 * a))
		h.draw_rect(Rect2(Vector2(bar.position.x, ycol.call(0.15)), Vector2(bar.size.x, ycol.call(-0.15) - ycol.call(0.15))), Color(0.35, 0.95, 0.45, 0.95 * a))
		var my: float = ycol.call(s.e_raw)
		h.draw_colored_polygon(PackedVector2Array([Vector2(bar.position.x - 4 * k, my), Vector2(bar.position.x - 16 * k, my - 8 * k), Vector2(bar.position.x - 16 * k, my + 8 * k)]), Color(1, 1, 1, a))
		game.draw_text(h, game.tr("力度"), Vector2(bar.get_center().x, bar.position.y - 12 * k), 15 * k, Color(pale, a), true)
		var word := game.tr("完美") if absf(s.e_raw) <= 0.15 else (game.tr("太轻") if s.e_raw < 0.0 else game.tr("太重"))
		game.draw_text(h, word, Vector2(bar.get_center().x, bar.end.y + 20 * k), 15 * k, Color(pale, a), true)

	# The shot's verdict.
	var fa := game._clock - s.flash_t
	if fa < 1.3:
		var a := clampf((1.3 - fa) / 0.4, 0.0, 1.0)
		var grow := 1.0 + 0.25 * maxf(0.0, 1.0 - fa * 6.0)
		# Keep verdicts below the shared rising score popups, including large text.
		game.draw_text(h, s.flash, Vector2(sz.x * 0.5, sz.y * 0.52), 46 * k * grow, Color(s.flash_col, a), true)

	if s.st == RSBasketballGame.St.SET and not p.fake:
		game.draw_text(h, game.tr("甩手腕 + 松开 B 出手"), Vector2(sz.x * 0.5, sz.y - 66 * k), 20 * k, Color(1, 1, 1, 0.8), true)
	if s.st == RSBasketballGame.St.DONE and game.phase == RSBasketballGame.Phase.PLAY:
		game.draw_text(h, game.tr("投完了！"), Vector2(sz.x * 0.5, sz.y * 0.72), 44 * k, RSBasketballGame.GOLD, true)
	if s.hint_t > 0.0:
		var a := clampf(s.hint_t, 0.0, 1.0)
		game.draw_pill(h, s.hint, Vector2(sz.x * 0.5, sz.y * 0.16), 17 * k, Color(1, 1, 1, a))



static func draw_overlay(game: RSBasketballGame, o: RSPartyGame.Overlay, k: float) -> void:
	var m := game._court.map
	if game.phase == RSBasketballGame.Phase.COUNTDOWN and game.phase_time < RSBasketballGame.INTRO:
		var a := clampf(game.phase_time / 0.6, 0.0, 1.0) * clampf((RSBasketballGame.INTRO - game.phase_time) / 0.6, 0.0, 1.0)
		game.draw_text(o, game.tr(str(m["name"])), Vector2(o.size.x * 0.5, o.size.y * 0.4), 84 * k, Color(1, 1, 1, a), true)
		game.draw_text(o, game.tr("%s  ·  三分大赛  ·  5 架 × 5 球  ·  %d 秒") % [m["en"], int(RSBasketballGame.TIME_LIMIT)],
			Vector2(o.size.x * 0.5, o.size.y * 0.4 + 56 * k), 24 * k, Color(1, 0.9, 0.6, a), true)
	elif game.phase == RSBasketballGame.Phase.COUNTDOWN:
		game.draw_text(o, game.tr("按住 B 举球，往上甩手腕 + 松开 B 出手"), Vector2(o.size.x * 0.5, o.size.y * 0.45 + 60 * k), 26 * k, Color(0.92, 0.95, 1.0), true)
	elif game.phase == RSBasketballGame.Phase.PLAY:
		game.draw_clock(o, game._time_left, k, 10.0, 0.83)
	elif game.phase == RSBasketballGame.Phase.RESULTS and game._podium_on:
		game._draw_podium_tags(o, k)



static func draw_replay(game: RSBasketballGame, h: RSPartyGame.PlayerHud, p: RSPartyGame.Player, k: float) -> void:
	var s := game._sh(p)
	var sz := h.size
	var bar := maxf(sz.y * 0.08, 64.0 * k)
	h.draw_rect(Rect2(Vector2.ZERO, Vector2(sz.x, bar)), Color(0.02, 0.02, 0.03))
	h.draw_rect(Rect2(Vector2(0, sz.y - bar), Vector2(sz.x, bar)), Color(0.02, 0.02, 0.03))
	game.draw_text(h, "P%d" % p.c.player, Vector2(20 * k, bar * 0.5 + 9 * k), 24 * k, game.color_of(p))
	if s.clip.size() < 2:
		game.draw_text(h, game.tr("这局一个都没进……"), Vector2(sz.x * 0.5, sz.y - bar * 0.5 + 8 * k), 22 * k, Color(0.92, 0.95, 1.0), true)
		return
	if fmod(game._clock, 1.0) < 0.6:
		h.draw_circle(Vector2(sz.x - 150 * k, bar * 0.5), 7 * k, Color(1.0, 0.25, 0.2))
	game.draw_text(h, "REPLAY", Vector2(sz.x - 136 * k, bar * 0.5 + 8 * k), 22 * k, Color.WHITE)
	game.draw_text(h, game.tr("最佳一投  ") + s.clip_name, Vector2(sz.x * 0.5, sz.y - bar - 44 * k), 22 * k, Color.WHITE, true)
	game.draw_text(h, "+%d" % s.clip_pts, Vector2(sz.x * 0.5, sz.y - bar - 8 * k), 40 * k, RSBasketballGame.GOLD, true)
