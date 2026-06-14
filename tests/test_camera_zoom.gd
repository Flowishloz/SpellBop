## test_camera_zoom.gd — Phase 2: the camera widens its default FOV (+15%) and
## tightens it (zoom in 15%) while the stack resolves in slow-mo, easing back to
## the base FOV as normal speed resumes (headless — FOV is a plain property).
##
## Run: <godot> --headless --path . -s res://tests/test_camera_zoom.gd
extends SceneTree

var _fails: int = 0


func _init() -> void:
	_run()


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


func _wait(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _run() -> void:
	await process_frame
	var arena: Node = load("res://scenes/match_arena.tscn").instantiate()
	var ai: Node = arena.get_node("Opponent/AIBrain")
	ai.cast_interval_ticks = 0
	ai.card_interval_ticks = 0
	ai.counter_enabled = false
	root.add_child(arena)
	await _wait(0.4)

	var cam: Camera3D = arena.get_node("Camera3D")
	var stack: Node = root.get_node("TheStack")

	# Default perspective: FOV widened ~15% from the authored 71.
	var base_fov: float = cam.fov
	_ck(base_fov > 78.0 and base_fov < 85.0, "default FOV widened ~15%% (%.1f, 71 -> ~81.6)" % base_fov)

	# Open the stack -> slow-mo -> camera tightens the FOV (zoom in).
	stack.stack_time_scale = 0.1
	stack.open_window(2.0)
	await _wait(0.6)
	_ck(cam.fov < base_fov - 3.0, "stack slow-mo ZOOMED IN (fov %.1f < base %.1f)" % [cam.fov, base_fov])
	var zoomed: float = cam.fov

	# Close -> resume -> FOV eases back to base.
	stack.close_window()
	await _wait(1.4)
	_ck(cam.fov > zoomed + 2.0 and absf(cam.fov - base_fov) < 1.5,
		"FOV eased back to base after resume (%.1f -> %.1f, base %.1f)" % [zoomed, cam.fov, base_fov])

	if _fails == 0:
		print("CAMERA ZOOM TEST: ALL PASS")
		quit(0)
	else:
		print("CAMERA ZOOM TEST: %d FAILURE(S)" % _fails)
		quit(1)
