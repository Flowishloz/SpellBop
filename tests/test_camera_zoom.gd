## test_camera_zoom.gd — Sprint 22: the camera FOV is LOCKED stable during play.
## The stack slow-mo NO LONGER zooms the lens (the old "dynamic stack zoom" was removed per
## the Creative Director) — the FOV stays at the widened base (+15%) whether or not the world
## is dilated, so the time-dilation reads without a camera push. (The death cam is the only
## remaining FOV change; it is not exercised here.)
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

	# Open the stack. The FOV must stay STABLE (the stack zoom was removed; Sprint 23 batch 3 also
	# removed the stack slow-mo, but this test only cares that the FOV doesn't move).
	stack.open_window(2.0)
	await _wait(0.6)
	_ck(absf(cam.fov - base_fov) < 1.0,
		"stack slow-mo keeps the FOV STABLE — no zoom (fov %.1f ~= base %.1f)" % [cam.fov, base_fov])

	# Close -> resume. The FOV is still stable at base (it never moved).
	stack.close_window()
	await _wait(1.4)
	_ck(absf(cam.fov - base_fov) < 1.0,
		"FOV stayed stable through the whole stack (%.1f, base %.1f)" % [cam.fov, base_fov])

	# CHARGE FRAMING (Sprint 22): charging a fireball SMOOTHLY tightens the FOV, DIPS the camera
	# down, and tilts it UP (a subtle in-the-action lean); all three snap back on release.
	# MatchController._ready wired the camera's charge source to the Player's SpellCasterComponent.
	var player: Node = arena.get_node("Player")
	var spell: Node = player.get_node("SpellCasterComponent")
	player.local_tick_driver_enabled = false      # take manual control of the caster
	var rest_y: float = cam.global_position.y
	var rest_pitch: float = cam.rotation_degrees.x
	for i in 70:
		spell._network_process({"c": 1})          # hold the cast -> build a strong charge
	await _wait(0.5)                               # let the camera ease in
	_ck(cam.fov < base_fov - 2.0, "charging ZOOMED the FOV in (%.1f < base %.1f)" % [cam.fov, base_fov])
	_ck(cam.global_position.y < rest_y - 0.2, "charging DIPPED the camera down (%.2f < rest %.2f)" % [cam.global_position.y, rest_y])
	_ck(cam.rotation_degrees.x > rest_pitch + 1.5, "charging tilted the camera UP (%.1f > rest %.1f)" % [cam.rotation_degrees.x, rest_pitch])
	var charged_fov: float = cam.fov
	spell._network_process({})                    # release -> fire -> snap back out
	await _wait(0.5)
	_ck(cam.fov > charged_fov + 2.0 and absf(cam.fov - base_fov) < 1.5,
		"releasing snapped the FOV back out (%.1f -> %.1f, base %.1f)" % [charged_fov, cam.fov, base_fov])
	_ck(absf(cam.global_position.y - rest_y) < 0.2 and absf(cam.rotation_degrees.x - rest_pitch) < 1.0,
		"camera height + pitch returned to rest after release")

	if _fails == 0:
		print("CAMERA FOV TEST: ALL PASS")
		quit(0)
	else:
		print("CAMERA FOV TEST: %d FAILURE(S)" % _fails)
		quit(1)
