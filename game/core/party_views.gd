class_name RSPartyViews
extends Control
## The players' split-screen views (part of RSPartyGame). Each player gets a cell: a SubViewport
## that renders the shared world through the player's own camera, with the player's HUD drawn
## on top. One player fills the screen, two sit side by side, three or four take quarters.
##
## A player's camera sees layer 1 plus its own layer (player number 2..5 as bits 1..4), so a
## game can show something to one player only (their aim line, their own ghost).

var game: RSPartyGame


func _init(owner_game: RSPartyGame) -> void:
	game = owner_game
	set_anchors_preset(PRESET_FULL_RECT)
	mouse_filter = MOUSE_FILTER_IGNORE


func _ready() -> void:
	get_viewport().size_changed.connect(layout)


func add(p: RSPartyGame.Player) -> void:
	## Build p's cell, camera and HUD (p.cell, p.cam, p.hud).
	p.cell = Control.new()
	p.cell.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(p.cell)
	var svc := SubViewportContainer.new()
	svc.stretch = true
	svc.set_anchors_preset(PRESET_FULL_RECT)
	svc.mouse_filter = MOUSE_FILTER_IGNORE
	p.cell.add_child(svc)
	var vp := SubViewport.new()
	vp.msaa_3d = Viewport.MSAA_2X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	RSSettings.apply_viewport(vp)
	svc.add_child(vp)
	p.cam = Camera3D.new()
	p.cam.far = 3000
	p.cam.fov = 72
	p.cam.cull_mask = 1 | (1 << p.c.player)   # layer 1 + this player's own layer (2..5)
	vp.add_child(p.cam)
	p.hud = RSPartyGame.PlayerHud.new()
	p.hud.player = p
	p.hud.game = game
	p.hud.set_anchors_preset(PRESET_FULL_RECT)
	p.hud.mouse_filter = MOUSE_FILTER_IGNORE
	p.cell.add_child(p.hud)


func remove(p: RSPartyGame.Player) -> void:
	p.cell.queue_free()


func layout() -> void:
	## Place the cells in player order (with sides, side by side: _view_order), with a thin gap
	## between them.
	var list := game._view_order()
	var n := list.size()
	var sz := get_viewport().get_visible_rect().size
	for i in n:
		var r := Rect2(Vector2.ZERO, sz)
		if n == 2:
			r = Rect2(Vector2(sz.x * 0.5 * i, 0.0), Vector2(sz.x * 0.5, sz.y))
		elif n > 2:
			r = Rect2(Vector2(sz.x * 0.5 * (i % 2), sz.y * 0.5 * (i >> 1)), sz * 0.5)
		var cell: Control = (list[i] as RSPartyGame.Player).cell
		cell.position = r.position + Vector2(2, 2) * float(n > 1)
		cell.size = r.size - Vector2(4, 4) * float(n > 1)
