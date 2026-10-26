## Exercise the same RID allocation contract on the main thread and worker threads.
## No game assets, autoloads or editor plugins are involved.
extends SceneTree

var _threads: Array[Thread] = []
var _kind := "mesh"
var _iterations := 2000
var _workers := 4
var _start := Semaphore.new()
var _finished := false


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--kind="):
			_kind = arg.get_slice("=", 1)
		elif arg.begins_with("--iterations="):
			_iterations = int(arg.get_slice("=", 1))
	assert(_kind in ["mesh", "material", "texture"])
	for _i in _workers:
		var thread := Thread.new()
		_threads.append(thread)
		var error := thread.start(_worker)
		assert(error == OK)
	for _i in _workers:
		_start.post()


func _worker() -> void:
	_start.wait()
	for _i in _iterations:
		_allocate_and_free()


func _process(_delta: float) -> bool:
	if _finished:
		print("RS_ENGINE_STRESS_DONE: ", _kind)
		return true
	for _i in 32:
		_allocate_and_free()
	for thread in _threads:
		if thread.is_alive():
			return false
	for thread in _threads:
		thread.wait_to_finish()
	# Let the normal main-loop synchronization drain queued RID frees before exit.
	_finished = true
	return false


func _allocate_and_free() -> void:
	match _kind:
		"mesh":
			var mesh := RenderingServer.mesh_create()
			var multimesh := RenderingServer.multimesh_create()
			RenderingServer.free_rid(mesh)
			RenderingServer.free_rid(multimesh)
		"material":
			var shader := RenderingServer.shader_create()
			var material := RenderingServer.material_create()
			RenderingServer.free_rid(shader)
			RenderingServer.free_rid(material)
		"texture":
			var texture := RenderingServer.texture_2d_placeholder_create()
			RenderingServer.free_rid(texture)
