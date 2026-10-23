class_name RSExit
extends RefCounted
## The one way the game ends (ARCH-QUIT). Stops gameplay and every audio player, then lets the
## audio thread release its playbacks on wall-clock time before quitting: fixed-fps runs and an
## instant quit both outpace the mixer, which otherwise reports the streams as leaked at exit.
## install() routes closing the window through the same path.

const DRAIN_MSEC := 350

static var _quitting := false


static func install(tree: SceneTree) -> void:
	## Called by the menu and every party game; only the first call connects.
	if not tree.auto_accept_quit:
		return
	tree.auto_accept_quit = false
	tree.root.close_requested.connect(func() -> void: quit(tree))


static func quit(tree: SceneTree, code: int = 0) -> void:
	## Callers return right after calling this; the process exits once audio has drained.
	if _quitting:
		return
	_quitting = true
	tree.paused = true   # no new hits, crowds or music cues while draining
	silence(tree.root)
	var drain_until := Time.get_ticks_msec() + DRAIN_MSEC
	while Time.get_ticks_msec() < drain_until:
		await tree.process_frame
	tree.quit(code)


static func silence(root: Node) -> void:
	for node: Node in root.find_children("*", "", true, false):
		if node is AudioStreamPlayer:
			(node as AudioStreamPlayer).stop()
			(node as AudioStreamPlayer).stream = null
		elif node is AudioStreamPlayer2D:
			(node as AudioStreamPlayer2D).stop()
			(node as AudioStreamPlayer2D).stream = null
		elif node is AudioStreamPlayer3D:
			(node as AudioStreamPlayer3D).stop()
			(node as AudioStreamPlayer3D).stream = null
