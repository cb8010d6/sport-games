class_name RSSkiHud
extends RefCounted
## Snow-readable run statistics. Text metrics keep the speed and tuck hint apart
## at either accessibility size; gameplay and timing remain owned by the scene.


static func draw_stats(game: RSPartyGame, h: RSPartyGame.PlayerHud, sk: RSSkier, gate_count: int, run_time: String, k: float, gold: Color) -> void:
	var sz := h.size
	var pale := Color(0.92, 0.95, 1.0)
	game._pill.set_corner_radius_all(RSUi.RADIUS)
	var gt := game.tr("旗门 %d/%d") % [sk.gates_hit, gate_count]
	if sk.gates_missed > 0:
		gt += game.tr("  漏 %d") % sk.gates_missed
	var gate_width := game.font.get_string_size(gt, HORIZONTAL_ALIGNMENT_LEFT, -1, RSUi.text_size(19 * k)).x + 16 * k
	h.draw_style_box(game._pill, Rect2(Vector2(12, 68) * k, Vector2(maxf(150 * k, gate_width), 54 * k)))
	var speed := "%d km/h" % roundi(sk.current_speed() * 3.6)
	var speed_end := 22 * k + game.font.get_string_size(speed, HORIZONTAL_ALIGNMENT_LEFT, -1, RSUi.text_size(22 * k)).x
	var tucked := sk.tuck > 0.5 and sk.mode == RSSkier.Mode.RIDE
	var tuck_x := maxf(130 * k, speed_end + 12 * k)
	var speed_end_with_hint := tuck_x + game.font.get_string_size(game.tr("团身"), HORIZONTAL_ALIGNMENT_LEFT, -1, RSUi.text_size(16 * k)).x if tucked else speed_end
	h.draw_style_box(game._pill, Rect2(Vector2(12 * k, sz.y - 46 * k), Vector2(maxf(170 * k, speed_end_with_hint), 36 * k)))
	game.draw_text(h, gt, Vector2(20 * k, 88 * k), 19 * k, pale)
	game.draw_text(h, run_time, Vector2(20 * k, 114 * k), 19 * k, gold if sk.finished else pale)

	game.draw_text(h, speed, Vector2(22 * k, sz.y - 20 * k), 22 * k, pale)
	if tucked:
		game.draw_text(h, game.tr("团身"), Vector2(tuck_x, sz.y - 20 * k), 16 * k, gold)
