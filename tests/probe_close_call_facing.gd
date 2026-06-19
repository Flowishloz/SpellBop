## probe_close_call_facing.gd — verifies CLOSE-CALL FACING (Task 2): a hostile ball that BARELY misses
## (crosses the baseline just outside the hitbox) makes the wizard FACE the side the ball passed on
## (flip_h toward it), independent of last-movement direction. Drives the animator's close-call scan with
## a ball placed on each side and checks the captured face dir + the resulting Sprite3D.flip_h.
## Run: <godot> --headless --path . -s res://tests/probe_close_call_facing.gd
extends SceneTree

var _fails: int = 0


func _ck(c: bool, label: String) -> void:
	if c:
		print("PASS: ", label)
	else:
		_fails += 1
		printerr("FAIL: ", label)


## Duck-typed lookup (NOT `is WizardAnimatorComponent`): referencing the class as a type forces the
## animator to compile at THIS probe's load time, before the SyncManager autoload global resolves
## (the autoload-compile-order gotcha). Finding it by node/method keeps the animator's compile at
## player.tscn instantiation, when the autoload is up.
func _find_animator(wiz: Node) -> Node:
	var direct: Node = wiz.get_node_or_null(^"WizardAnimator")
	if direct != null:
		return direct
	for c in wiz.get_children():
		if c.has_method(&"_scan_close_call"):
			return c
	return null


func _init() -> void:
	_run()


func _place(body: Node, x: int, y: int) -> void:
	body.set_global_fixed_position(SGFixed.vector2(SGFixed.from_int(x), SGFixed.from_int(y)))
	body.sync_to_physics_engine()


## Drive a near-miss on one side: seed the baseline (frame A, not crossed), then cross it (frame B) with
## the ball at +/- dx_units. Returns the animator's captured face dir afterward.
func _near_miss(anim: Node, fb: Node, dx_units: int) -> void:
	var now: int = Time.get_ticks_msec()
	_place(fb, dx_units, 10)   # frame A: ball on the far side of our baseline (dy < 0)
	anim._scan_close_call(now)
	_place(fb, dx_units, -10)  # frame B: ball crossed our baseline (dy > 0) — the near-miss frame
	anim._scan_close_call(now)


func _run() -> void:
	await process_frame
	var container := Node.new()
	container.name = "Projectiles"
	root.add_child(container)
	var wiz: Node = load("res://scenes/player.tscn").instantiate()
	root.add_child(wiz)
	await process_frame
	if "local_tick_driver_enabled" in wiz:
		wiz.local_tick_driver_enabled = false
	_place(wiz, 0, 0)
	var anim: Node = _find_animator(wiz)
	_ck(anim != null, "wizard has a WizardAnimatorComponent")
	if anim == null:
		quit(1)
		return

	var fb: Node = load("res://scenes/fireball.tscn").instantiate()
	fb.local_tick_driver_enabled = false
	container.add_child(fb)
	await process_frame
	# Place the ball just OUTSIDE the (now 35-unit) hitbox but inside the close-call margin, ball-size aware.
	var ext: SGFixedVector2 = fb.get_collider_half_extents()
	var dx_units: int = 35 + (ext.x >> 16) + 40

	# --- RIGHT near-miss (+X): face right == flip_h false (art is drawn facing right) ---
	_near_miss(anim, fb, dx_units)
	_ck(anim._close_call_face_dir == 1, "ball on the RIGHT -> face dir +1 (got %d)" % anim._close_call_face_dir)
	anim._process(0.0)
	_ck(anim._sprite.flip_h == false, "RIGHT near-miss: wizard faces the ball (flip_h false)")

	# reset the per-ball tracking + the close-call latch for the second case
	anim._ball_prev_dy.clear()
	anim._close_call_until_msec = 0
	anim._close_call_face_dir = 0

	# --- LEFT near-miss (-X): face left == flip_h true ---
	_near_miss(anim, fb, -dx_units)
	_ck(anim._close_call_face_dir == -1, "ball on the LEFT -> face dir -1 (got %d)" % anim._close_call_face_dir)
	anim._process(0.0)
	_ck(anim._sprite.flip_h == true, "LEFT near-miss: wizard faces the ball (flip_h true)")

	if _fails == 0:
		print("CLOSE-CALL FACING PROBE: ALL PASS")
		quit(0)
	else:
		print("CLOSE-CALL FACING PROBE: %d FAILURE(S)" % _fails)
		quit(1)
